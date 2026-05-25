#!/usr/bin/env python3
"""Example read-side bot client for the Lyn Rummy chat API.

Streams one conversation's messages — the same JSON payloads the web
client consumes (rendered `html`, the on-disk `enc`/transcript form, plus
metadata) — and pretty-prints each. This tool only reads, but the API key
itself acts as the member (read + write); set GOPHER_API_KEY in the
environment, never paste the key into a prompt or hard-code it here.

Usage:
    GOPHER_API_KEY=<key> python3 fetch_conversation.py <base_url> <partner_id>

Both args are required. `base_url` is explicit on purpose — there is no
default, so you always state whether you're hitting your local dev server
(http://localhost:9000) or production (https://lynrummy.com) rather than
relying on a silent default. `partner_id` is the numeric id of the other
member.

For the prod Steve<->Apoorva transcript, prefer the zero-arg wrapper
`ops/fetch_prod_transcript`, which supplies the prod URL + the key for you
(Steve hates remembering command-line arguments).

The stream replays the full backlog (since=0) then goes live; this tool
exits after the first idle gap, so it's a one-shot look at what the API
returns. Stdlib only — no install step.
"""
import json, os, socket, sys, urllib.error, urllib.request


def main():
    key = os.environ.get("GOPHER_API_KEY")
    if not key:
        sys.exit("set GOPHER_API_KEY to a chat API key")
    if len(sys.argv) != 3:
        sys.exit("usage: fetch_conversation.py <base_url> <partner_id>\n"
                 "       (for the prod transcript, prefer: ops/fetch_prod_transcript)")
    base = sys.argv[1].rstrip("/")
    partner = sys.argv[2]

    url = f"{base}/chat/stream?with={partner}&since=0"
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
