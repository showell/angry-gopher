#!/usr/bin/env python3
"""**EVERY SITE LOGS** (metal-vmm QUEUE 221): each site block in the Caddy
files named imports `access_log` (deploy/Caddyfile's snippet), so every site
on prod writes /var/log/caddy/<name>-access.log. Exits non-zero naming each
block that doesn't.

    deploy/check_caddy_logs.py [file ...]

With no files, deploy/Caddyfile. Dog Park's and roc's blocks live in their
own repositories (dog-park droplet/dogpark.lynrummy.com.caddy, roc-apps
ops/roc.lynrummy.com.caddy); name them to check them too.

A site block is a block at the file's top level that is neither the global
options (`{` alone) nor a snippet (`(name) {`). Braces inside quotes are not
counted; `#` starts a comment.
"""
import os
import re
import sys

IMPORT = re.compile(r"^\s*import\s+access_log\s+\S+\s*$")


def strip(line: str) -> str:
    """The line without its comment and without what is quoted."""
    out, quoted = [], False
    for ch in line:
        if ch == '"':
            quoted = not quoted
            continue
        if quoted:
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)


def site_blocks(text: str):
    """Each top-level site block as (its first line's number, its address
    line, whether it imports access_log)."""
    blocks, depth, current = [], 0, None
    for n, raw in enumerate(text.splitlines(), 1):
        line = strip(raw)
        if depth == 0 and line.strip().endswith("{"):
            head = line.strip()[:-1].strip()
            if head and not head.startswith("("):
                current = [n, head, False]
                blocks.append(current)
            else:
                current = None
        elif depth == 1 and current is not None and IMPORT.match(line):
            current[2] = True
        depth += line.count("{") - line.count("}")
        if depth == 0:
            current = None
    return blocks


def missing(path: str):
    """The site blocks of `path` that log nowhere, as messages."""
    with open(path) as f:
        return [f"{path}:{n}: the site block `{head}` does not `import access_log <name>`"
                for n, head, logs in site_blocks(f.read()) if not logs]


def main(argv) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    files = argv or [os.path.join(here, "Caddyfile")]
    bad = [m for p in files for m in missing(p)]
    for m in bad:
        print(m)
    if bad:
        print(f"check_caddy_logs: {len(bad)} site block(s) log nowhere: who knocked would be lost")
        return 1
    print(f"check_caddy_logs: every site block logs ({len(files)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
