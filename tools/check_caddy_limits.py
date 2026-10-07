#!/usr/bin/env python3
"""**CADDY'S BODY CAPS AGAINST THE APPLICATION'S** (zig-server/src/limits.zig).

Caddy refuses a body before the application sees it, so its caps must let
through everything the application allows: an upload up to
`body.upload_any`, and any other body up to `body.largest_ordinary`. A cap
below that refuses at the door what a route would take; one more than twice
it is a cap nobody kept up to date. Both fail.

    tools/check_caddy_limits.py          (ops/check_zig runs it)

Caddy reads sizes as go-humanize does: `MB` is 1,000,000 bytes and `MiB`
1,048,576.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LIMITS = os.path.join(ROOT, "zig-server", "src", "limits.zig")
CADDY = os.path.join(ROOT, "deploy", "Caddyfile")

UNITS = {"": 1, "B": 1, "KB": 1000, "MB": 1000 ** 2, "GB": 1000 ** 3,
         "KIB": 1024, "MIB": 1024 ** 2, "GIB": 1024 ** 3}


def body_limits() -> dict:
    """`limits.zig`'s `body` constants, evaluated in order."""
    text = open(LIMITS).read()
    start = text.index("pub const body = struct {") + len("pub const body = struct {")
    vals = {}
    for m in re.finditer(r"pub const (\w+) = ([^;]+);", text[start:]):
        name, expr = m.group(1), m.group(2).strip()
        mx = re.fullmatch(r"@max\(([^)]*)\)", expr)
        if mx:
            vals[name] = max(vals[a.strip()] for a in mx.group(1).split(","))
        else:
            vals[name] = eval(expr, {}, dict(vals))
    return vals


def caddy_caps() -> dict:
    """The `max_size` under each `request_body <matcher>` block."""
    caps = {}
    matcher = None
    for line in open(CADDY):
        t = line.strip()
        m = re.match(r"request_body\s+(@\w+)\s*\{", t)
        if m:
            matcher = m.group(1)
            continue
        m = re.match(r"max_size\s+(\d+)\s*([A-Za-z]*)", t)
        if m and matcher:
            caps[matcher] = int(m.group(1)) * UNITS[m.group(2).upper()]
            matcher = None
    return caps


def main() -> int:
    body = body_limits()
    caps = caddy_caps()
    checks = [("@upload", "an upload", body["upload_any"]),
              ("@notupload", "any other body", body["largest_ordinary"])]
    bad = 0
    for matcher, what, allowed in checks:
        if matcher not in caps:
            print(f"caddy limits: no request_body {matcher} in {CADDY}")
            return 2
        cap = caps[matcher]
        if cap < allowed:
            print(f"  {what}: Caddy refuses past {cap:,} bytes, and the application allows {allowed:,}")
            bad += 1
        elif cap > 2 * allowed:
            print(f"  {what}: Caddy lets through {cap:,} bytes, more than twice the application's {allowed:,}")
            bad += 1
        else:
            print(f"  {what}: Caddy {cap:,} bytes, the application {allowed:,}")
    if bad:
        print(f"CADDY LIMITS: {bad} out of line with zig-server/src/limits.zig")
        return 1
    print("CADDY LIMITS: Caddy lets through what the application allows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
