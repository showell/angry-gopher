#!/usr/bin/env python3
"""The `webbox` library is the files its two roots name, and only those.

The library is two modules: `webbox` (src/webbox.zig, portable, what every
application imports) and `webbox_linux` (src/webbox_linux.zig, the Linux
host, which only a Linux `main` imports). For each root:

- every file reachable from it by a relative @import must be one the root
  imports itself, so membership is said in one place, and a library file
  that reaches for the rest of angry-gopher (users, the chat) fails here
  rather than dragging the application into every program built on it;
- its files import only the modules it may: `std` and `builtin` for
  `webbox`, and also `webbox` for `webbox_linux` (the Linux host reaches the
  portable half as the module, never by path: one file, one module);
- no file embeds a file (`@embedFile`): what a page serves is the
  application's.

And for every other file in the folder, the application's (whatever builds
it, or nothing does: a bench run by hand): it imports the library by name,
`@import("webbox").x` or `@import("webbox_linux").x`, never a library file by
path. One file belongs to one module.

Imports are read by zig_source, the reading the portability lint shares: an
import split over lines counts, one in a comment does not.

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


# Each root, and the named modules its files may import.
ROOTS = {
    "webbox.zig": {"std", "builtin"},
    "webbox_linux.zig": {"std", "builtin", "webbox"},
}


def problems(src):
    out = []
    for root, may in ROOTS.items():
        out += problems_of(src, root, may)
    library = members(src)
    for name in sorted(os.listdir(src)):
        if not name.endswith(".zig") or name in library:
            continue
        for dep in imports(os.path.join(src, name)):
            if os.path.basename(dep) in library:
                out.append(f"{name} imports {dep} by path: an application imports the library by name (@import(\"webbox\") or @import(\"webbox_linux\"))")
    return out


def members(src):
    """The library's files: each root and the files it names."""
    out = set()
    for root in ROOTS:
        path = os.path.join(src, root)
        if os.path.exists(path):
            out |= {root} | set(imports(path))
    return out


def problems_of(src, root_name, may_import):
    root = os.path.join(src, root_name)
    if not os.path.exists(root):
        return [f"{root_name}: the library's root, and not there"]
    named = set(imports(root))
    seen, todo, out = set(), list(named), []
    for m in zig_source.modules(read(root)):
        if m not in may_import:
            out.append(f"{root_name} imports the module {m}, which it may not")
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
                out.append(f"{name} imports {dep}, which {root_name} does not name: the library reaches outside itself")
                continue  # said once, at the edge; what lies past it is not the library's
            todo.append(dep)
        for m in zig_source.modules(read(path)):
            if m not in may_import:
                out.append(f"{name} imports the module {m}, which {root_name}'s files may not")
    return out


def self_test():
    with tempfile.TemporaryDirectory() as d:
        def write(name, body):
            with open(os.path.join(d, name), "w") as f:
                f.write(body)
        write("webbox.zig", 'pub const a = @import("a.zig");\npub const b = @import("b.zig");\n')
        write("webbox_linux.zig", "\n")
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
        write("b.zig", 'const std = @import("std");\n')
        # The Linux half: its files reach the portable half as the module.
        write("webbox_linux.zig", 'pub const host = @import("host.zig");\n')
        write("host.zig", 'const w = @import("webbox");\nconst std = @import("std");\n')
        assert problems(d) == [], problems(d)
        write("host.zig", 'const a = @import("a.zig");\n')
        got = problems(d)
        assert len(got) == 1 and "host.zig imports a.zig, which webbox_linux.zig does not name" in got[0], got
        write("host.zig", 'const w = @import("webbox");\n')
        write("b.zig", 'const l = @import("webbox_linux");\n')
        got = problems(d)
        assert len(got) == 1 and "b.zig imports the module webbox_linux" in got[0], got
        # A portable file importing its own module: the module is not one its
        # files may name.
        write("b.zig", 'const w = @import("webbox");\n')
        got = problems(d)
        assert len(got) == 1 and "b.zig imports the module webbox" in got[0], got
        write("b.zig", 'const std = @import("std");\n')
        # An application's file, built by something or nothing, imports the
        # library by name; by path, or by "./", is a finding.
        write("app.zig", 'const a = @import("webbox").a;\nconst l = @import("webbox_linux").host;\n')
        assert problems(d) == [], problems(d)
        for spelling in ("a.zig", "./a.zig", "host.zig", "webbox.zig"):
            write("app.zig", f'const a = @import("{spelling}");\n')
            got = problems(d)
            assert len(got) == 1 and f"app.zig imports {spelling} by path" in got[0], (spelling, got)
        write("app.zig", 'const u = @import("users.zig");\n')
        assert problems(d) == [], problems(d)
    print("lint_webbox_library: its self-test passes (a clean library; one reaching outside, on one line or split; a commented import; an embedded file; the Linux half through the module, not by path; the portable half reaching for the Linux one, or for itself; an application's file by name, never by path)")


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
    print("webbox library: every file each root reaches, it names; each imports only the modules it may")
    return 0


if __name__ == "__main__":
    sys.exit(main())
