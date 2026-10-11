#!/usr/bin/env python3
"""The `webbox` library is the files src/webbox.zig names, and only those.

Every file reachable from zig-server/src/webbox.zig by a relative @import must
be one webbox.zig imports itself, so the library's membership is said in one
place, and a library file that reaches for the rest of angry-gopher (users,
store, the chat) fails here rather than dragging the application into every
program built on it.

    lint_webbox_library.py            check the tree
    lint_webbox_library.py --self-test
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
    print("lint_webbox_library: its self-test passes (a clean library, and one reaching outside)")


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
