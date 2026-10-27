#!/usr/bin/env python3
"""angry-gopher's files reach the `webbox` and `shale` libraries by name, never
by path.

Each library is two modules: `webbox` (zig-webbox's src/webbox.zig, portable,
what every application imports) and `webbox_linux` (its src/webbox_linux.zig,
the Linux host, which only a Linux `main` imports); `shale` and `shale_linux`
(the shale checkout's src/shale.zig and src/shale_linux.zig) the same.
**webbox's own shape** (what each root reaches it names, the modules each
half may import, no page embedded, every module's tests run) **is
zig-webbox's to check**, in its src/library_test.zig, on every webbox change.
This lint checks angry-gopher's side: every file in angry-gopher's folder
that is not a library's imports it by name, `@import("webbox").x` or
`@import("shale").x` (or a Linux half), never a library file by path, and
embeds none of them. One file belongs to one module. And no file of a
library is in angry-gopher's own folder, where it would shadow the library's.

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

ROOTS = ("webbox.zig", "webbox_linux.zig", "shale.zig", "shale_linux.zig")
# Test roots a library's build runs beside its modules, in a binary of their
# own (shale's Zig tools' tests, metal-vmm QUEUE 252): they and the tests they
# import are the library's, though no module root reaches them.
TEST_ROOTS = ("shale_zig_tools_test.zig",)


def read(path):
    with open(path) as f:
        return f.read()


def imports(path):
    return zig_source.imports(read(path))


def library(src):
    """(the libraries' files, their own tests): what each root reaches by a
    relative import, and the `*_test.zig` files reached from them, which are
    the libraries' and compiled by no application."""
    members, tests = set(), set()
    for root in ROOTS:
        if not os.path.exists(zig_source.at(src, root)):
            continue
        todo = [root]
        while todo:
            name = todo.pop()
            if name in members:
                continue
            members.add(name)
            path = zig_source.at(src, name)
            if not os.path.exists(path):
                continue
            for raw in imports(path):
                dep = os.path.normpath(os.path.join(os.path.dirname(name), raw))
                if dep.startswith(".."):
                    continue
                if dep.endswith("_test.zig"):
                    tests.add(dep)
                else:
                    todo.append(dep)
    for root in TEST_ROOTS:
        path = zig_source.at(src, root)
        if not os.path.exists(path):
            continue
        tests.add(root)
        for raw in imports(path):
            dep = os.path.normpath(os.path.join(os.path.dirname(root), raw))
            if dep.endswith("_test.zig") and not dep.startswith(".."):
                tests.add(dep)
    return members, tests


def problems(src):
    out = []
    members, tests = library(src)
    names = {os.path.basename(m) for m in members}
    for name in zig_source.listing(src):
        if not name.endswith(".zig") or name in members or name in tests:
            continue
        text = read(zig_source.at(src, name))
        for dep in zig_source.imports(text):
            if os.path.basename(dep) in names:
                out.append(f"{name} imports {dep} by path: an application imports a library by name (@import(\"webbox\"), @import(\"shale\") or a Linux half)")
        for embedded in zig_source.embeds(text):
            if os.path.basename(embedded) in names:
                out.append(f"{name} embeds {embedded}, a file of the library, by path: the build hands it over by name (addAnonymousImport)")
    return out


def self_test():
    with tempfile.TemporaryDirectory() as d:
        def write(name, body):
            with open(os.path.join(d, name), "w") as f:
                f.write(body)
        write("webbox.zig", 'pub const a = @import("a.zig");\n')
        write("webbox_linux.zig", 'pub const host = @import("host.zig");\n')
        write("a.zig", 'const std = @import("std");\ntest {\n    _ = @import("a_test.zig");\n}\n')
        write("a_test.zig", 'const a = @import("a.zig");\nconst s = @embedFile("a.zig");\n')
        write("host.zig", 'const w = @import("webbox");\n')
        # An application's file imports the library by name.
        write("app.zig", 'const a = @import("webbox").a;\nconst l = @import("webbox_linux").host;\n')
        assert problems(d) == [], problems(d)
        # By path, or by "./", is a finding, on one line or split.
        for spelling in ("a.zig", "./a.zig", "host.zig", "webbox.zig"):
            write("app.zig", f'const a = @import("{spelling}");\n')
            got = problems(d)
            assert len(got) == 1 and f"app.zig imports {spelling} by path" in got[0], (spelling, got)
        write("app.zig", 'const a = @import(\n    "a.zig",\n);\n')
        got = problems(d)
        assert len(got) == 1 and "app.zig imports a.zig by path" in got[0], got
        write("app.zig", '// const a = @import("a.zig");\n')
        assert problems(d) == [], problems(d)
        # Its own files are its own; the library's tests are not the app's.
        write("app.zig", 'const u = @import("users.zig");\n')
        assert problems(d) == [], problems(d)
        write("app.zig", 'const s = @embedFile("a.zig");\n')
        got = problems(d)
        assert len(got) == 1 and "app.zig embeds a.zig, a file of the library" in got[0], got
        write("app.zig", 'const s = @embedFile("webbox_store_source");\n')
        assert problems(d) == [], problems(d)
        # A test root of its own, and the tests it imports, are the library's.
        write("b_test.zig", 'const a = @import("a.zig");\n')
        got = problems(d)
        assert len(got) == 1 and "b_test.zig imports a.zig by path" in got[0], got
        write(TEST_ROOTS[0], 'test {\n    _ = @import("b_test.zig");\n}\n')
        assert problems(d) == [], problems(d)
    print("lint_webbox_library: its self-test passes (an application's file by name; by path, on one line or split, or embedding one, a finding; a commented import none; the library's own tests not the application's)")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    src = zig_source.TREE
    found = problems(src)
    # A library lives in its own checkout: a file of it in the application's
    # folder would shadow the library's own (the lints read the
    # application's folder first) and be compiled by nothing.
    members, _ = library(src)
    for name in sorted(members | {"host_io_std.zig"}):
        if os.path.exists(os.path.join(zig_source.APP_SRC, name)):
            found.append(f"{name} is a file of a library, and is in angry-gopher's zig-server/src: it lives in that library's checkout")
    for p in found:
        print("webbox library:", p)
    if found:
        return 1
    print("webbox library: angry-gopher reaches webbox and shale by name, never by path (webbox's own shape: zig-webbox's library_test.zig)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
