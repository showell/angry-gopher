#!/usr/bin/env python3
"""Group a user's external chat links by sender, then platform.

Builds on link_feed.py: same dedup pass over the same chat data dir, but the
output is bucketed — top level by WHO shared the link (Steve & apoorva
dominate), then by platform within each person. The big platforms (YouTube,
LinkedIn, GitHub, X, Zulip, Google) get named buckets; everything else falls
into a sorted "Other" long tail (bloggers and such).

Each link keeps the context of the message that introduced it (who shared it,
when, in which conv/topic, and the body text) — that context is what lets a
human or an agent identify the link without fetching it. So this output
doubles as the raw material for a curated links page.

Pure stdlib, no network. Reuses link_feed so the parsing/dedup never forks.

    python3 chat/link_groups.py <chat_dir> [--uid 1] [--out link_groups.md]
"""
import argparse
import os
import sys
from urllib.parse import urlsplit

from link_feed import collect, deduped_messages

# Ordered: first matching bucket wins. Each is (title, host-predicate). A host
# is the lowercased urlsplit hostname (no port). Order matters only for the
# few hosts that could plausibly match two rules — none currently do.
BUCKETS = [
    ("YouTube", lambda h: h in ("www.youtube.com", "youtube.com", "m.youtube.com", "youtu.be")),
    ("LinkedIn", lambda h: h == "www.linkedin.com" or h.endswith(".linkedin.com") or h == "linkedin.com"),
    ("GitHub", lambda h: h == "github.com" or h.endswith(".github.com") or h.endswith(".github.io")),
    ("X / Twitter", lambda h: h in ("x.com", "twitter.com", "mobile.twitter.com")),
    ("Zulip", lambda h: "zulip" in h),
    ("Google", lambda h: h.endswith(".google.com")),
]
OTHER = "Other"


def bucket_for(url):
    host = (urlsplit(url).hostname or "").lower()
    for title, pred in BUCKETS:
        if pred(host):
            return title
    return OTHER


def link_records(chat_dir, uid):
    """One record per unique external URL, with its introducing message context."""
    recs = []
    for msg in deduped_messages(collect(chat_dir, uid)):
        for url in msg["new_urls"]:
            recs.append({
                "url": url, "from": msg["from"], "date": msg["date"],
                "conv": msg["conv"], "topic": msg["topic"], "body": msg["body"],
            })
    return recs


def render(recs, uid, chat_dir):
    # Two levels: WHO shared it (top), then platform within that person. Senders
    # are ordered by share-count (Steve & apoorva dominate), platforms in BUCKETS
    # order then Other. Records are already chronological, so each leaf is too.
    by_sender = {}
    for r in recs:
        by_sender.setdefault(r["from"], []).append(r)
    sender_order = sorted(by_sender, key=lambda s: (-len(by_sender[s]), s))
    platform_order = [t for t, _ in BUCKETS] + [OTHER]

    lines = [
        f"# Grouped links for uid {uid}",
        f"# source: {os.path.abspath(chat_dir)}",
        f"# {len(recs)} unique external links from {len(by_sender)} senders",
        "",
    ]
    for sender in sender_order:
        rs = by_sender[sender]
        lines.append(f"## {sender} ({len(rs)})")
        lines.append("")
        groups = {title: [] for title in platform_order}
        for r in rs:
            groups[bucket_for(r["url"])].append(r)
        for title in platform_order:
            grs = groups[title]
            if not grs:
                continue
            lines.append(f"### {title} ({len(grs)})")
            for r in grs:
                # One self-contained entry per link: the URL, where/when, and the
                # body the link arrived in (squashed to one line, blank lines kept
                # out so each entry is one grep-able unit).
                ctx = " / ".join(ln.strip() for ln in r["body"].splitlines() if ln.strip())
                lines.append(f"- {r['url']}")
                lines.append(f"  {r['date']} · {r['conv']}/{r['topic']}")
                if ctx:
                    lines.append(f"  context: {ctx}")
            lines.append("")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Group a user's external chat links by platform.")
    ap.add_argument("chat_dir", help="path to a chat data dir ({data_dir}/chat or a backup snapshot)")
    ap.add_argument("--uid", type=int, default=1, help="user id whose transcripts to scan (default 1)")
    ap.add_argument("--out", default="link_groups.md", help="output file (default link_groups.md)")
    args = ap.parse_args()

    if not os.path.isdir(args.chat_dir):
        sys.exit(f"not a directory: {args.chat_dir}")

    recs = link_records(args.chat_dir, args.uid)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(render(recs, args.uid, args.chat_dir))

    counts = {}
    for r in recs:
        counts[r["from"]] = counts.get(r["from"], 0) + 1
    summary = ", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1]))
    print(f"{len(recs)} links -> {args.out}  ({summary})", file=sys.stderr)


if __name__ == "__main__":
    main()
