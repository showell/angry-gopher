#!/usr/bin/env python3
"""The front-end assets zig-server embeds, read from build.zig's own table.

    embedded_assets.py check      every generated asset is there, and every
                                  embedded file git does not track names its
                                  builder; exit 1 with guidance otherwise
    embedded_assets.py builders   the scripts that build them, once each, in
                                  the table's order (ops/build_embedded runs them)

**ONE READING OF THE TABLE** (metal-vmm QUEUE 157(d), and its review): ops/
check_zig, ops/start and the stress harness each kept a list of their own
(check_zig's had lost delivery/app.js; the stress harness's had no delivery or
chess). A row this cannot read is an error, never skipped: it counts the
table's names and every row must be one it read.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROW = re.compile(r'\.\{\s*\.name\s*=\s*"([^"]+)"\s*,\s*\.path\s*=\s*"\.\./([^"]+)"\s*(?:,\s*\.built_by\s*=\s*"([^"]+)"\s*)?\}')
NAME = re.compile(r'\.name\s*=\s*"')


def rows():
    whole = open(os.path.join(ROOT, "zig-server", "build.zig")).read()
    start = whole.find("const assets = [_]")
    if start < 0:
        sys.exit("embedded_assets: no asset table in zig-server/build.zig")
    table = whole[start:whole.find("\n    };", start)]
    got = ROW.findall(table)
    names = len(NAME.findall(table))
    if len(got) != names:
        sys.exit(f"embedded_assets: {names} assets in build.zig's table, but {len(got)} rows read: has a row changed shape?")
    return got


def check():
    bad = []
    for _, path, by in rows():
        full = os.path.join(ROOT, path)
        tracked = subprocess.run(["git", "-C", ROOT, "ls-files", "--error-unmatch", path], capture_output=True).returncode == 0
        if by and not os.path.isfile(full):
            bad.append(f"{path} missing: run {by} first (embedded by zig build), or ops/build_embedded")
        elif not by and not tracked:
            bad.append(f"{path} is embedded and not in git, but build.zig names no .built_by for it")
    if bad:
        print("Error:\n  " + "\n  ".join(bad), file=sys.stderr)
        return 1
    return 0


def builders():
    seen = []
    for _, _, by in rows():
        if by and by not in seen:
            seen.append(by)
    print("\n".join(seen))
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) == 2 else ""
    if cmd == "check":
        sys.exit(check())
    if cmd == "builders":
        sys.exit(builders())
    sys.exit(__doc__)
