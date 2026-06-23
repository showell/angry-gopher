#!/usr/bin/env python3
"""Poka-yoke lint: confine raw request-head access to http.zig.

Reading the request BODY invalidates the std.http head strings (the zig-0.16
`received_head` gotcha). A borrowed slice of `req.head.target` or of a header
value (reached via `req.iterateHeaders()`) that is used AFTER a body read
silently becomes garbage — which once mis-attributed an authenticated chat post
to the wrong principal (see the empty/wrong-author bug).

http.zig is the single owning chokepoint: its `header` / `target` / `cookie`
accessors return memory OWNED by the caller's allocator, so a head value you hold
can never dangle. Every other module MUST go through them. This lint fails the
build if any module besides http.zig touches the raw head, which is what makes
the foot-gun impossible to reintroduce rather than merely fixed once.

Run by ops/check_zig (so it rides every subsystem gate). Comment text is ignored
(only the code before `//` is checked), so docs may name the forbidden patterns.
"""
import glob
import os
import sys

SRC = os.path.join(os.path.dirname(__file__), "..", "zig-server", "src")
ALLOWED = {"http.zig"}  # the owning chokepoint — raw head access lives here only

FORBIDDEN = [
    ("head.target", "use http.target(req, alloc) — it returns an owned copy"),
    ("iterateHeaders()", "use http.header / http.cookie — they return owned copies"),
]


def code_part(line):
    """The line with any trailing // comment stripped (so docs can name patterns)."""
    i = line.find("//")
    return line if i < 0 else line[:i]


def main():
    violations = []
    for path in sorted(glob.glob(os.path.join(SRC, "*.zig"))):
        if os.path.basename(path) in ALLOWED:
            continue
        with open(path) as f:
            for n, line in enumerate(f, 1):
                code = code_part(line)
                for needle, fix in FORBIDDEN:
                    if needle in code:
                        violations.append((os.path.relpath(path), n, needle, fix, line.strip()))

    if violations:
        print("head-access lint: raw request-head access outside http.zig (a body read would clobber it)")
        for rel, n, needle, fix, text in violations:
            print(f"  {rel}:{n}: `{needle}` — {fix}")
            print(f"      {text}")
        sys.exit(1)

    print("head-access lint: clean (raw head access confined to http.zig).")


if __name__ == "__main__":
    main()
