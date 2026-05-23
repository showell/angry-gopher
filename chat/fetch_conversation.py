#!/usr/bin/env python3
"""Example read-only bot client for the Lyn Rummy chat API.

Streams one conversation's messages — the same JSON payloads the web
client consumes (rendered `html`, the on-disk `enc`/transcript form, plus
metadata) — and pretty-prints each. Authenticates with a member's
*read-only* API key: set GOPHER_API_KEY in the environment, never paste
the key into a prompt or hard-code it here.

Usage:
    GOPHER_API_KEY=<key> python3 fetch_conversation.py <partner_id> [base_url]

`partner_id` is the numeric id of the other member. `base_url` defaults to
https://lynrummy.com. The stream replays the full backlog (since=0) then
goes live; this tool exits after the first idle gap, so it's a one-shot
look at what the API returns. Stdlib only — no install step.
"""
import json, os, socket, sys, urllib.error, urllib.request


def main():
    key = os.environ.get("GOPHER_API_KEY")
    if not key:
        sys.exit("set GOPHER_API_KEY to a read-only chat API key")
    if len(sys.argv) < 2:
        sys.exit("usage: fetch_conversation.py <partner_id> [base_url]")
    partner = sys.argv[1]
    base = sys.argv[2] if len(sys.argv) > 2 else "https://lynrummy.com"

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
