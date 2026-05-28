#!/usr/bin/env python3
"""Example read-side bot client for the Lyn Rummy chat API.

Streams one conversation session — the same JSON payloads the web
client consumes (rendered `html`, the on-disk `enc`/transcript form, plus
metadata) — and pretty-prints each. This tool only reads, but the API key
itself acts as the principal (read + write); set GOPHER_API_KEY in the
environment, never paste the key into a prompt or hard-code it here.

Usage:
    GOPHER_API_KEY=<key> python3 fetch_conversation.py <base_url> <partner_id> [<session_id>]

`base_url` is explicit on purpose — there is no default, so you always
state whether you're hitting your local dev server
(http://localhost:9000) or production (https://lynrummy.com) rather than
relying on a silent default. `partner_id` is the numeric id of the other
member; the conv key (smaller_id_larger_id) is derived. `session_id` is
optional — if omitted we follow the `/chat/c/<conv>` 303 to find the
default session for this principal (which is the newest existing
session, or the user's last-viewed if they have one). We catch the
redirect rather than following it so we never hit the conversation page
handler, which would have the side effect of moving the principal's
last-viewed pointer.

For the prod Steve<->Apoorva transcript, prefer the zero-arg wrapper
`ops/fetch_prod_transcript`, which supplies the prod URL + the key for
you (Steve hates remembering command-line arguments).

The stream replays the full backlog (since=0) then goes live; this tool
exits after the first idle gap, so it's a one-shot look at what the API
returns. Stdlib only — no install step.
"""
import json, os, socket, sys, urllib.error, urllib.request


class _StopRedirect(urllib.request.HTTPRedirectHandler):
    """Don't follow redirects: return None to signal 'give up', which
    surfaces the redirect as an HTTPError that carries the Location."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _resolve_session(base, conv, key):
    """Follow-without-following: ask /chat/c/<conv> for the default
    session and read it out of the 303 Location header. Avoids triggering
    HandleChatPage (which would update the principal's last-viewed
    pointer as a side effect of a passive read)."""
    req = urllib.request.Request(
        f"{base}/chat/c/{conv}",
        headers={"Authorization": f"Bearer {key}"},
    )
    opener = urllib.request.build_opener(_StopRedirect)
    try:
        opener.open(req, timeout=5)
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 303, 307, 308):
            sys.exit(f"resolve session: {e.code} {e.reason}")
        loc = e.headers.get("Location", "")
        if not loc:
            sys.exit("resolve session: 303 had no Location header")
        # Location is .../chat/c/<conv>/<sid>
        return loc.rsplit("/", 1)[-1]
    sys.exit("resolve session: expected a 303 redirect")


def main():
    key = os.environ.get("GOPHER_API_KEY")
    if not key:
        sys.exit("set GOPHER_API_KEY to a chat API key")
    if not (3 <= len(sys.argv) <= 4):
        sys.exit("usage: fetch_conversation.py <base_url> <partner_id> [<session_id>]\n"
                 "       (for the prod transcript, prefer: ops/fetch_prod_transcript)")
    base = sys.argv[1].rstrip("/")
    partner = sys.argv[2]
    explicit_sid = sys.argv[3] if len(sys.argv) == 4 else None

    # The API key embeds the principal's id as its prefix (see api_key.go);
    # the conv key is the two ids sorted numerically, joined by "_".
    my_id, sep, _ = key.partition("-")
    if not sep or not my_id.isdigit() or not partner.isdigit():
        sys.exit("API key or partner id is malformed")
    a, b = sorted([int(my_id), int(partner)])
    conv = f"{a}_{b}"

    sid = explicit_sid or _resolve_session(base, conv, key)

    url = f"{base}/chat/c/{conv}/{sid}/stream?since=0"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    try:
        resp = urllib.request.urlopen(req, timeout=5)  # also bounds idle reads
    except urllib.error.HTTPError as e:
        sys.exit(f"request failed: {e.code} {e.reason}")
    if "text/event-stream" not in resp.headers.get("Content-Type", ""):
        sys.exit("unexpected response — is the API key valid?")

    try:
        for raw in resp:  # the backlog arrives at once; idle read -> timeout -> exit
            line = raw.decode("utf-8").rstrip("\n")
            if line.startswith("data:"):
                msg = json.loads(line[5:].lstrip())
                print(json.dumps(msg, indent=2, ensure_ascii=False))
                print("-" * 60)
    except (socket.timeout, TimeoutError):
        pass


if __name__ == "__main__":
    main()
