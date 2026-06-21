#!/usr/bin/env python3
"""Collect every external link a user has seen in chat into one combined feed.

Walks a chat data directory (the on-disk `{data_dir}/chat` tree, or an
unpacked `ops/backup` snapshot of it), finds the conversations a given user
is in (their DM dirs `<a>_<b>` plus any channel they're a member of), and
extracts each message that *introduces* a not-yet-seen external URL. The
output is a transcript-shaped "link feed": same `MSG_/from:/date:` shape as a
real transcript, plus a couple of extra header lines (`conv:`, `topic:`,
`link:`) so the source conversation/topic of every link is tracked.

The point is to save agent tokens: instead of an agent reading 30+ full
transcripts to build a curated links page, it reads this one deduped feed.
A follow-up tool can group the `link:` lines (YouTube / LinkedIn / the
blogger long tail) on top of this output.

Pure stdlib, no network — it reads files. To run against real (prod) data,
unpack a backup tarball and point `chat_dir` at its `chat/` directory.

    python3 chat/link_feed.py <chat_dir> [--uid N] [--out FILE]

`--uid` defaults to 1 (Steve). `--out` defaults to link_feed.md in the cwd;
the feed is also summarized on stderr.
"""
import argparse
import os
import re
import sys
from urllib.parse import urlsplit

# A message transcript is blocks joined by a line of EXACTLY thirteen dashes.
# (60-dash lines are in-body <hr> thematic breaks; an escaped "\-------------"
# in a body is 14 chars incl. the backslash — neither matches this.)
SEP_RE = re.compile(r"(?m)^-{13}$")

# Grab http(s) URLs whether bare or inside a [text](url) markdown link. The
# char class stops at ) ] " ' ` < > and whitespace, so "[t](url)" yields "url".
URL_RE = re.compile(r"""https?://[^\s<>()\[\]"'`]+""")

# Hosts that are "us", not a link worth curating. Anything else is external —
# including apoorva's granite.* and personal sites, which ARE real links.
INTERNAL_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "162.243.1.123"}


def is_external(url):
    host = (urlsplit(url).hostname or "").lower()
    if not host:
        return False
    if host in INTERNAL_HOSTS:
        return False
    if host == "lynrummy.com" or host.endswith(".lynrummy.com"):
        return False
    return True


def extract_urls(text):
    """External URLs in `text`, in order, trailing sentence punctuation trimmed."""
    out = []
    for m in URL_RE.finditer(text):
        url = m.group(0).rstrip(".,;:!?")
        if is_external(url):
            out.append(url)
    return out


def parse_messages(text):
    """Yield (msg_id, from, date, body) for each message block in a transcript."""
    for block in SEP_RE.split(text):
        block = block.strip("\n")
        if not block.strip():
            continue
        lines = block.split("\n")
        msg_id = lines[0].strip()
        headers, i = {}, 1
        while i < len(lines) and lines[i].strip() != "":
            key, _, val = lines[i].partition(":")
            headers[key.strip()] = val.strip()
            i += 1
        body = "\n".join(lines[i + 1:]).strip("\n")
        yield msg_id, headers.get("from", "?"), headers.get("date", ""), body


def channel_members(channel_file):
    members = set()
    with open(channel_file, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.isdigit():
                members.add(int(line))
    return members


def find_convs(chat_dir, uid):
    """List (conv_label, sessions_dir) the user participates in."""
    convs = []
    for name in sorted(os.listdir(chat_dir)):
        path = os.path.join(chat_dir, name)
        if not os.path.isdir(path):
            continue
        if name == "channels":
            for ch in sorted(os.listdir(path)):
                if not ch.endswith(".channel"):
                    continue
                base = ch[: -len(".channel")]
                if uid in channel_members(os.path.join(path, ch)):
                    sessions = os.path.join(path, base, "sessions")
                    if os.path.isdir(sessions):
                        convs.append((f"channel:{base}", sessions))
            continue
        m = re.fullmatch(r"(\d+)_(\d+)", name)
        if m and uid in (int(m.group(1)), int(m.group(2))):
            sessions = os.path.join(path, "sessions")
            if os.path.isdir(sessions):
                convs.append((name, sessions))
    return convs


def collect(chat_dir, uid):
    """All messages (across the user's convs) that contain >=1 external URL."""
    msgs = []
    for conv_label, sessions in find_convs(chat_dir, uid):
        for fn in sorted(os.listdir(sessions)):
            if not fn.endswith(".md"):
                continue
            topic = fn[:-3]
            with open(os.path.join(sessions, fn), encoding="utf-8", errors="replace") as f:
                text = f.read()
            for msg_id, frm, date, body in parse_messages(text):
                urls = extract_urls(body)
                if urls:
                    msgs.append({
                        "id": msg_id, "from": frm, "date": date,
                        "conv": conv_label, "topic": topic,
                        "body": body, "urls": urls,
                    })
    return msgs


def build_feed(msgs):
    """Render the deduped feed; a message appears at the FIRST sight of each URL."""
    seen, blocks, n_links = set(), [], 0
    for msg in sorted(msgs, key=lambda m: (m["date"], m["conv"], m["id"])):
        new = [u for u in dict.fromkeys(msg["urls"]) if u not in seen]
        if not new:
            continue
        seen.update(new)
        n_links += len(new)
        header = [
            msg["id"],
            f"from: {msg['from']}",
            f"date: {msg['date']}",
            f"conv: {msg['conv']}",
            f"topic: {msg['topic']}",
        ]
        header += [f"link: {u}" for u in new]
        blocks.append("\n".join(header) + "\n\n" + msg["body"])
    return blocks, len(seen), n_links


def main():
    ap = argparse.ArgumentParser(description="Combined external-link feed from chat transcripts.")
    ap.add_argument("chat_dir", help="path to a chat data dir ({data_dir}/chat or a backup snapshot)")
    ap.add_argument("--uid", type=int, default=1, help="user id whose transcripts to scan (default 1)")
    ap.add_argument("--out", default="link_feed.md", help="output file (default link_feed.md)")
    args = ap.parse_args()

    if not os.path.isdir(args.chat_dir):
        sys.exit(f"not a directory: {args.chat_dir}")

    msgs = collect(args.chat_dir, args.uid)
    blocks, n_urls, n_links = build_feed(msgs)

    preamble = (
        f"# Link feed for uid {args.uid}\n"
        f"# source: {os.path.abspath(args.chat_dir)}\n"
        f"# {len(blocks)} messages introduce {n_urls} unique external links\n"
    )
    body = preamble + "\n" + "\n\n-------------\n".join(blocks) + "\n"
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(body)

    print(f"{len(blocks)} messages, {n_urls} unique external links -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
