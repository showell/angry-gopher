#!/usr/bin/env python3
"""Reference client for the Lyn Rummy chat API (https://lynrummy.com/chat).

One module owns all addressing, so the read and write paths can't drift
apart (they did once: a bash poster kept hitting a dead pre-session URL).
This client is also the worked example for OTHER clients of the API.

The model has two axes — conversation partner × time-bucketed session — so
every call starts from discovery and then acts on a chosen (conv, sid):

  conversations()          GET  /chat/conversations
      the whole (partner × time) matrix you can see: each conversation
      you're in, its sessions (newest-first), and the `default` session a
      bare /chat/c/<conv> would land on. Small, so one call returns it all.

  read(conv, sid)          GET  /chat/c/<conv>/<sid>/stream?since=0
      replay one session's transcript (the SSE backlog, then idle-exit).

  post(conv, sid, markdown)  POST /chat/c/<conv>/<sid>/send (form field `markdown`)
      append one message.

Discovery is a passive read (no last-viewed pointer is moved), so a bot can
inspect the matrix without disturbing the user's place. The key acts as the
principal (read + write, never admin); set GOPHER_API_KEY in the
environment — never hard-code or paste a key. base_url is explicit (no
default) so localhost-vs-prod is never silent.

Docs (the per-user authoring surface) ride the same key + base_url:

  docs()           GET /chat/docs/list       the key-holder's docs (slug+title)
  read_doc(slug)   GET /chat/docs/<slug>.md  one doc's raw markdown (the file)

CLI (the ops/ wrappers call these; you normally run the wrappers):

    GOPHER_API_KEY=… python3 chat_client.py conversations <base_url>
    GOPHER_API_KEY=… python3 chat_client.py fetch <base_url> <partner> [<sid>]
    GOPHER_API_KEY=… python3 chat_client.py post  <base_url> <partner> [<sid>]
                                                    (markdown on stdin)
    GOPHER_API_KEY=… python3 chat_client.py docs-list <base_url>
    GOPHER_API_KEY=… python3 chat_client.py docs-read <base_url> <slug>

`partner` is the other principal's numeric id; the conv key and the default
session are taken from the matrix, so the client never re-derives them.
Stdlib only — no install step.
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

# One-shot reads block this long waiting for more stream data; the backlog
# arrives at once, then the idle gap trips this timeout and we exit.
READ_TIMEOUT = 5
# Plain request/response calls (discovery, posting) just need a sane bound.
RPC_TIMEOUT = 10


class ChatClient:
    """Addressing + the three verbs, over a single (base_url, key)."""

    def __init__(self, base_url, key):
        self.base = base_url.rstrip("/")
        self.key = key

    def _request(self, path, *, data=None, method=None, extra_headers=None):
        headers = {"Authorization": f"Bearer {self.key}"}
        if extra_headers:
            headers.update(extra_headers)
        return urllib.request.Request(self.base + path, data=data, method=method, headers=headers)

    def conversations(self):
        """The whole (partner × time) matrix the key-holder can see."""
        req = self._request("/chat/conversations")
        try:
            with urllib.request.urlopen(req, timeout=RPC_TIMEOUT) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            sys.exit(f"conversations failed: {e.code} {e.reason}")

    def resolve(self, partner, sid=None):
        """Map a partner id to (conv, sid). sid defaults to that
        conversation's current default session (from the matrix)."""
        partner = str(partner)
        for c in self.conversations().get("conversations", []):
            if c["partner"]["id"] == partner:
                return c["conv"], (sid or c["default"])
        sys.exit(f"no conversation with partner {partner}")

    def read(self, conv, sid):
        """Yield each message of one session (SSE backlog, since=0)."""
        path = f"/chat/c/{conv}/{urllib.parse.quote(sid)}/stream?since=0"
        try:
            resp = urllib.request.urlopen(self._request(path), timeout=READ_TIMEOUT)
        except urllib.error.HTTPError as e:
            sys.exit(f"read failed: {e.code} {e.reason}")
        if "text/event-stream" not in resp.headers.get("Content-Type", ""):
            sys.exit("unexpected response — is the API key valid?")
        try:
            for raw in resp:
                line = raw.decode("utf-8").rstrip("\n")
                if line.startswith("data:"):
                    yield json.loads(line[5:].lstrip())
        except (socket.timeout, TimeoutError):
            pass  # idle gap = end of the one-shot backlog

    def post(self, conv, sid, markdown):
        """Append one message to a session (raises on a non-204 reply)."""
        data = urllib.parse.urlencode({"markdown": markdown}).encode()
        req = self._request(
            f"/chat/c/{conv}/{urllib.parse.quote(sid)}/send",
            data=data,
            method="POST",
            extra_headers={
                "X-Chat-Async": "1",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=RPC_TIMEOUT) as resp:
                if resp.status != 204:
                    sys.exit(f"post failed: HTTP {resp.status}")
        except urllib.error.HTTPError as e:
            sys.exit(f"post failed: {e.code} {e.reason}")

    def docs(self):
        """List the key-holder's docs (slug + display title)."""
        req = self._request("/chat/docs/list")
        try:
            with urllib.request.urlopen(req, timeout=RPC_TIMEOUT) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            sys.exit(f"docs list failed: {e.code} {e.reason}")

    def read_doc(self, slug):
        """Return one doc's raw markdown — the literal <slug>.md file."""
        path = f"/chat/docs/{urllib.parse.quote(slug)}.md"
        try:
            with urllib.request.urlopen(self._request(path), timeout=RPC_TIMEOUT) as resp:
                return resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            sys.exit(f"doc read failed: {e.code} {e.reason}")


def _new_client(base_url):
    key = os.environ.get("GOPHER_API_KEY")
    if not key:
        sys.exit("set GOPHER_API_KEY to a chat API key")
    return ChatClient(base_url, key)


def main():
    argv = sys.argv[1:]
    if len(argv) < 2:
        sys.exit("usage: chat_client.py <conversations|fetch|post|docs-list|docs-read> <base_url> [arg]\n"
                 "       (for prod, prefer the ops/ wrappers: list_prod_sessions,\n"
                 "        fetch_prod_transcript, post_summary, list_prod_docs, fetch_prod_doc)")
    cmd, base = argv[0], argv[1]
    client = _new_client(base)

    if cmd == "conversations":
        print(json.dumps(client.conversations(), indent=2, ensure_ascii=False))
        return

    if cmd == "docs-list":
        print(json.dumps(client.docs(), indent=2, ensure_ascii=False))
        return

    if cmd == "docs-read":
        if len(argv) < 3:
            sys.exit("usage: chat_client.py docs-read <base_url> <slug>")
        sys.stdout.write(client.read_doc(argv[2]))
        return

    if cmd in ("fetch", "post"):
        if len(argv) < 3:
            sys.exit(f"usage: chat_client.py {cmd} <base_url> <partner> [<sid>]"
                     + ("  (markdown on stdin)" if cmd == "post" else ""))
        partner = argv[2]
        explicit_sid = argv[3] if len(argv) > 3 else None
        conv, sid = client.resolve(partner, explicit_sid)
        if cmd == "fetch":
            for msg in client.read(conv, sid):
                print(json.dumps(msg, indent=2, ensure_ascii=False))
                print("-" * 60)
        else:
            client.post(conv, sid, sys.stdin.read())
            print(f"posted to {conv}/{sid}")
        return

    sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
