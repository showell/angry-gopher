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
  `webbox` (and `host_io`, the one file a build swaps to name the host),
  and also `webbox` for `webbox_linux` (the Linux host reaches the
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


def resolved(importer, dep):
    """`dep` as the library names it: relative to the folder of the file
    that imports it (zig's own rule), e.g. `script/diag.zig`."""
    return os.path.normpath(os.path.join(os.path.dirname(importer), dep))


def vouched(dep, named):
    """**A FOLDER THE ROOT NAMES A FILE OF IS THE LIBRARY'S** (metal-vmm
    QUEUE 199-200): Shale lives in `script/`, and the root names its entry
    (`script/script.zig`); the files that entry reaches inside its folder
    are the library's too. A file at the top is the root's to name."""
    folder = os.path.dirname(dep)
    return folder != "" and not folder.startswith("..") and any(os.path.dirname(n) == folder for n in named)


# Each root, and the named modules its files may import.
ROOTS = {
    "webbox.zig": {"std", "builtin", "host_io"},
    "webbox_linux.zig": {"std", "builtin", "host_io", "webbox"},
}


def problems(src):
    out = []
    tests = set()
    for root, may in ROOTS.items():
        out += problems_of(src, root, may, tests)
    library = members(src)
    for name in zig_source.listing(src):
        if not name.endswith(".zig") or name in library or name in tests:
            continue
        text = read(zig_source.at(src, name))
        for dep in zig_source.imports(text):
            if os.path.basename(dep) in library:
                out.append(f"{name} imports {dep} by path: an application imports the library by name (@import(\"webbox\") or @import(\"webbox_linux\"))")
        for embedded in zig_source.embeds(text):
            if os.path.basename(embedded) in library:
                out.append(f"{name} embeds {embedded}, a file of the library, by path: the build hands it over by name (addAnonymousImport)")
    return out


def members(src):
    """The library's files: each root and the files it names."""
    out = set()
    for root in ROOTS:
        path = zig_source.at(src, root)
        if os.path.exists(path):
            out |= {root} | set(imports(path))
    return out


def is_test(name):
    """**THE LIBRARY'S OWN TESTS** (`*_test.zig`, reached from a library
    file's `test` block): compiled only by zig-webbox's `zig build test`,
    with its own modules, never into an application, so they may embed the
    sources they check and name test options. Recorded, not walked."""
    return name.endswith("_test.zig")


def problems_of(src, root_name, may_import, tests=None):
    root = zig_source.at(src, root_name)
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
        path = zig_source.at(src, name)
        if not os.path.exists(path):
            out.append(f"{name}: imported by the library, and not there")
            continue
        for embedded in zig_source.embeds(read(path)):
            out.append(f"{name} embeds {embedded}: what a page serves is the application's, not the library's")
        for raw in imports(path):
            dep = resolved(name, raw)
            if is_test(dep):
                if tests is not None:
                    tests.add(dep)
                continue
            if dep not in named and not vouched(dep, named):
                out.append(f"{name} imports {raw}, which {root_name} does not name: the library reaches outside itself")
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
        # A folder the root names a file of: what that file reaches in its
        # folder is the library's; outside it, it is not.
        os.mkdir(os.path.join(d, "sub"))
        write("webbox.zig", 'pub const a = @import("a.zig");\npub const b = @import("b.zig");\npub const s = @import("sub/s.zig");\n')
        write("sub/s.zig", 'const t = @import("t.zig");\nconst std = @import("std");\n')
        write("sub/t.zig", 'const s = @import("../users.zig");\n')
        got = problems(d)
        assert len(got) == 1 and "sub/t.zig imports ../users.zig" in got[0], got
        write("sub/t.zig", 'const std = @import("std");\n')
        assert problems(d) == [], problems(d)
        # The library's own test, reached from its test block: it may embed
        # and name its options, and is not an application's file.
        write("b.zig", 'const std = @import("std");\ntest {\n    _ = @import("b_test.zig");\n}\n')
        write("b_test.zig", 'const b = @import("b.zig");\nconst o = @import("test_options");\nconst s = @embedFile("b.zig");\n')
        assert problems(d) == [], problems(d)
        os.remove(os.path.join(d, "b_test.zig"))
        write("b.zig", 'const std = @import("std");\n')
        write("webbox.zig", 'pub const a = @import("a.zig");\npub const b = @import("b.zig");\n')
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
        write("app.zig", 'const s = @embedFile("a.zig");\n')
        got = problems(d)
        assert len(got) == 1 and "app.zig embeds a.zig, a file of the library" in got[0], got
        write("app.zig", 'const s = @embedFile("webbox_store_source");\n')
        assert problems(d) == [], problems(d)
    print("lint_webbox_library: its self-test passes (a clean library; one reaching outside, on one line or split; a commented import; an embedded file; the Linux half through the module, not by path; the portable half reaching for the Linux one, or for itself; an application's file by name, never by path, nor embedding one)")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    src = zig_source.TREE
    found = problems(src)
    # The library lives in zig-webbox: a file of it in the application's
    # folder would shadow the library's own (the lints read the
    # application's folder first) and be compiled by nothing.
    for name in sorted(members(src) | {"host_io_std.zig"}):
        if os.path.exists(os.path.join(zig_source.APP_SRC, name)):
            found.append(f"{name} is a file of the library, and is in angry-gopher's zig-server/src: it lives in zig-webbox")
    for p in found:
        print("webbox library:", p)
    if found:
        return 1
    print("webbox library: every file each root reaches, it names; each imports only the modules it may")
    return 0


if __name__ == "__main__":
    sys.exit(main())
