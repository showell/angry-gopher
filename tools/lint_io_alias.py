#!/usr/bin/env python3
"""Poka-yoke lint: the `Io` alias is the porting seam — keep everything on it.

Every module that touches the filesystem, the clock or a lock opens with

    const Io = std.Io;

and spells its calls `Io.Dir.cwd().readFileAlloc(io, ...)`. That one line is the
ENTIRE port to a machine with no operating system: gopher-metal copies these
sources and rewrites it to `const Io = @import("metal").io;`, and not one call
site moves.

So a call spelled `std.Io.Dir` instead of `Io.Dir` is a call the port cannot
reach — and it does not merely behave differently there, it fails to COMPILE,
because `std.Io.Dir.cwd()` reaches for `std.posix.AT.FDCWD`, which does not
exist on a freestanding target. The same goes for a signature that names
`std.Io` as a parameter type.

This is not hypothetical. Compiling the route table against that machine found
twenty-one such signatures in four files, and then six more of these namespaces,
one at a time, each hiding behind the last. The lint exists so the next one is a
build failure here rather than an afternoon there.

WHAT STAYS `std.`:
  std.Io.Reader / std.Io.Writer   genuine interfaces — one required method,
                                  defaults for the rest, no POSIX in their
                                  types. std.http.Server is built from them and
                                  runs unmodified on bare metal.
  std.Io.Limit                    a plain enum.
  std.Io.Threaded / std.Io.net    the thread pool and sockets: host-only by
                                  definition. Allowed inside a `test {}` block
                                  (tests run on the host) and in any file that
                                  declares `pub fn main` (it IS a host).

Run by ops/check_zig, so it rides every subsystem gate. Comment text is ignored
(only the code before `//` is checked), so docs may name the forbidden spellings.
"""
import glob
import os
import re
import sys

# The namespaces gopher-metal's src/io.zig provides. Reached through the alias
# they port; reached through `std.` they do not.
PORTED = ("Dir", "Clock", "Mutex", "Group")

# Host-only by definition, and allowed only in the files that own the host.
HOST_ONLY = ("Threaded", "net")

# A file that declares `pub fn main` IS a host: it owns the process, so it is
# entitled to a thread pool and a socket. That covers the server and the
# standalone tools (the stress harness, the markdown bench and probe, the
# regression runner) — and it keeps covering the next one without editing this
# list, which a hardcoded set would not.
HOST_DECL = "pub fn main("

BAD_NS = re.compile(r"\bstd\.Io\.(" + "|".join(PORTED) + r")\b")
# A bare `std.Io` in a signature or a declaration: `io: std.Io`, `!std.Io`, etc.
# Excludes `std.Io.Anything`, which the namespace rules above cover.
BAD_BARE = re.compile(r"\bstd\.Io\b(?!\s*\.)")


def code(line: str) -> str:
    """The part of a line before any comment. `//!` and `///` count too."""
    at = line.find("//")
    return line if at < 0 else line[:at]


def test_lines(lines):
    """The 1-based line numbers inside a `test {}` block.

    Tests run on the HOST — they spin a real std.Io.Threaded and write to a real
    temp directory. None of that has to port, so none of it is this lint's
    business. Braces inside string literals are skipped, which is enough for
    zig test blocks.
    """
    inside, depth, out = False, 0, set()
    for n, line in enumerate(lines, 1):
        c = code(line)
        if not inside and c.lstrip().startswith("test ") and depth == 0:
            inside = True
        if inside:
            out.add(n)
        in_str = False
        for i, ch in enumerate(c):
            if ch == '"' and (i == 0 or c[i - 1] != "\\"):
                in_str = not in_str
            elif not in_str and ch == "{":
                depth += 1
            elif not in_str and ch == "}":
                depth -= 1
                if inside and depth <= 0:
                    inside, depth = False, 0
    return out


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(here, "..", "zig-server", "src")
    bad = []

    for path in sorted(glob.glob(os.path.join(src, "*.zig"))):
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
        if any(HOST_DECL in code(l) for l in lines):
            continue  # a host: see HOST_DECL
        in_test = test_lines(lines)
        for n, line in enumerate(lines, 1):
            if n in in_test:
                continue
            c = code(line)
            if "const Io = std.Io;" in c:
                continue  # the alias itself
            for m in BAD_NS.finditer(c):
                bad.append((name, n, m.group(0), "use Io.%s — the alias is the port" % m.group(1)))
            for m in BAD_BARE.finditer(c):
                bad.append((name, n, "std.Io", "use Io — the alias is the port"))
            for ns in HOST_ONLY:
                if f"std.Io.{ns}" in c:
                    bad.append((name, n, f"std.Io.{ns}",
                                "host-only: it belongs in a test, or in a file with its own main"))

    if not bad:
        print("io-alias lint: every Io call is on the alias")
        return 0

    print("io-alias lint FAILED — these cannot compile on a freestanding target:", file=sys.stderr)
    for name, n, found, why in bad:
        print(f"  {name}:{n}: {found} — {why}", file=sys.stderr)
    print("\nSee the docstring in tools/lint_io_alias.py for what legitimately stays `std.`.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
