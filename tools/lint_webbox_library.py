#!/usr/bin/env python3
"""The `webbox` library is the files src/webbox.zig names, and only those.

Every file reachable from zig-server/src/webbox.zig by a relative @import must
be one webbox.zig imports itself, so the library's membership is said in one
place, and a library file that reaches for the rest of angry-gopher (users,
the chat) fails here rather than dragging the application into every program
built on it. Nor may a library file embed a file (`@embedFile`): what a page
serves is the application's.

Imports are read by zig_source, the reading the portability lint shares: an
import split over lines counts, one in a comment does not. A named module
(`@import("build_options")`) is not a file here; the library's own test
module, which has none, is what refuses it.

    lint_webbox_library.py            check the tree
    lint_webbox_library.py --self-test
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zig_source  # noqa: E402


def read(path):
    with open(path) as f:
        return f.read()


def imports(path):
    return zig_source.imports(read(path))


def problems(src):
    root = os.path.join(src, "webbox.zig")
    named = set(imports(root))
    seen, todo, out = set(), list(named), []
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        path = os.path.join(src, name)
        if not os.path.exists(path):
            out.append(f"{name}: imported by the library, and not there")
            continue
        for embedded in zig_source.embeds(read(path)):
            out.append(f"{name} embeds {embedded}: what a page serves is the application's, not the library's")
        for dep in imports(path):
            if dep not in named:
                out.append(f"{name} imports {dep}, which webbox.zig does not name: the library reaches outside itself")
            todo.append(dep)
    return out


def self_test():
    with tempfile.TemporaryDirectory() as d:
        def write(name, body):
            with open(os.path.join(d, name), "w") as f:
                f.write(body)
        write("webbox.zig", 'pub const a = @import("a.zig");\npub const b = @import("b.zig");\n')
        write("a.zig", 'const std = @import("std");\nconst b = @import("b.zig");\n')
        write("b.zig", 'const std = @import("std");\n')
        assert problems(d) == [], problems(d)
        write("b.zig", 'const users = @import("users.zig");\n')
        write("users.zig", "")
        got = problems(d)
        assert len(got) == 1 and "b.zig imports users.zig" in got[0], got
        write("b.zig", 'const users = @import(\n    "users.zig",\n);\n')
        got = problems(d)
        assert len(got) == 1 and "b.zig imports users.zig" in got[0], got
        write("b.zig", '// const users = @import("users.zig");\n')
        assert problems(d) == [], problems(d)
        write("b.zig", 'const page = @embedFile("chat.js");\n')
        got = problems(d)
        assert len(got) == 1 and "b.zig embeds chat.js" in got[0], got
    print("lint_webbox_library: its self-test passes (a clean library; one reaching outside, on one line or split; a commented import; an embedded file)")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-server", "src")
    found = problems(src)
    for p in found:
        print("webbox library:", p)
    if found:
        return 1
    print("webbox library: every file it reaches, webbox.zig names")
    return 0


if __name__ == "__main__":
    sys.exit(main())
