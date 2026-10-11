#!/usr/bin/env python3
"""The `gopher` library is the files src/gopher.zig names, and only those.

Every file reachable from zig-server/src/gopher.zig by a relative @import must
be one gopher.zig imports itself, so the library's membership is said in one
place, and a library file that reaches for the rest of angry-gopher (users,
store, the chat) fails here rather than dragging the application into every
program built on gopher.

    lint_gopher_library.py            check the tree
    lint_gopher_library.py --self-test
"""
import os
import re
import sys
import tempfile

IMPORT = re.compile(r'@import\("([^"]+\.zig)"\)')


def imports(path):
    with open(path) as f:
        return IMPORT.findall(f.read())


def problems(src):
    root = os.path.join(src, "gopher.zig")
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
        for dep in imports(path):
            if dep not in named:
                out.append(f"{name} imports {dep}, which gopher.zig does not name: the library reaches outside itself")
            todo.append(dep)
    return out


def self_test():
    with tempfile.TemporaryDirectory() as d:
        def write(name, body):
            with open(os.path.join(d, name), "w") as f:
                f.write(body)
        write("gopher.zig", 'pub const a = @import("a.zig");\npub const b = @import("b.zig");\n')
        write("a.zig", 'const std = @import("std");\nconst b = @import("b.zig");\n')
        write("b.zig", 'const std = @import("std");\n')
        assert problems(d) == [], problems(d)
        write("b.zig", 'const users = @import("users.zig");\n')
        write("users.zig", "")
        got = problems(d)
        assert len(got) == 1 and "b.zig imports users.zig" in got[0], got
    print("lint_gopher_library: its self-test passes (a clean library, and one reaching outside)")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-server", "src")
    found = problems(src)
    for p in found:
        print("gopher library:", p)
    if found:
        return 1
    print("gopher library: every file it reaches, gopher.zig names")
    return 0


if __name__ == "__main__":
    sys.exit(main())
