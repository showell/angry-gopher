#!/usr/bin/env python3
"""Poka-yoke lint: nothing the route table reaches may reach for the host.

`zig-server/src/router.zig` is WHAT THIS SITE SERVES, and it is deliberately
separate from how a Linux process starts (webbox's `linux_host.zig`, which
`server.zig` calls). The point of the
split is that the route table can be called by a host that is not Linux:
gopher-metal boots it on a machine with no operating system. That only works if
every module the route table transitively imports stays off the host — and a
module that does not is not a slower path there. It FAILS TO COMPILE.

This lint computes that set from the import graph, starting at router.zig and
at webbox.zig (the library an application built on this server imports, which
the metal port carries too, whether or not this site's routes reach a file of
it), and checks every file in it. It follows a file's imports by path and its
import of the `webbox` module (to webbox.zig). A module outside the set
(server.zig, the library's Linux half `webbox_linux`, the stress harness, the
markdown tools) is host-side by definition and is not checked. There is no
hardcoded list of exemptions to fall out of date.

THE LIBRARY'S EDGES, inside the set:

  THE LINUX HALF     `@import("webbox_linux")`, or a file of it by path
                     (linux_host.zig, bind.zig, linux_config.zig,
                     webbox_linux.zig): the host itself.
  BY ITS FILES       an application's file importing a file of the library
                     by path (`@import("http.zig")`, `@import("webbox.zig")`):
                     it imports the `webbox` module (`@import("webbox").http`).
                     One file belongs to one module, and the metal port hands
                     the library to the kernel as a module of its own.

WHAT IT FORBIDS, inside the set and outside `test {}` blocks:

  THE HOST'S SEAM    Every file takes its `Io` from the `host_io` module
                     (`const Io = @import("host_io").Io;`), one file each build
                     chooses: std's on Linux, the machine's on gopher-metal. So
                     `std.Io.Dir`, `.Clock`, `.Mutex` and `.Group` (the
                     namespaces that machine replaces) are spelled through
                     `Io`, and so is a bare `std.Io` in a signature, the old
                     `const Io = std.Io;` alias included. Spelled `std.` they
                     are std's on every host, and `std.Io.Dir.cwd()` reaches
                     for `std.posix.AT.FDCWD`.
  THE STORE'S SEAM   `Io.Dir.cwd()` anywhere but store.zig (gopher-metal QUEUE
                     item 54). The Store is the one way to the disk: it keeps
                     FAT's rules (case, names, lengths) on every host, so a
                     direct call beside it is a path where Linux and the
                     machine with no operating system can answer differently.
  THE HOST ITSELF    Thread pools and sockets (`std.Io.Threaded`, `std.Io.net`),
                     host allocators (`std.heap.page_allocator` and friends —
                     page_allocator is mmap), `std.process`, `std.posix`,
                     `std.os`, `std.c`, `std.Thread`, the wall-clock shortcuts in
                     `std.time`, `std.crypto.random` (a getrandom syscall), the
                     old `std.fs` file API, and `std.debug.print` (stderr).

WHAT IT ALLOWS:

  std.Io.Reader / std.Io.Writer   genuine interfaces — one required method,
                                  defaults for the rest. std.http.Server is built
                                  from them and runs unmodified on bare metal.
  std.Io.Limit                    a plain enum.
  std.fs.path                     string manipulation; no file system.
  anything in a `test {}` block   tests run on the host: they spin a real thread
                                  pool and write to a real temp directory.
  a test's own helper             a private top-level `fn` or `const` that only
                                  tests (or other such helpers) name. Zig
                                  compiles a declaration only where it is used,
                                  so one only tests use is never in the route
                                  table's build. A `pub` one may be used from
                                  another file, and is checked.

WHAT IT CANNOT SEE. A std function that takes a real `std.Io` compiles on
Linux when handed our `io`, because there the alias IS std.Io. This lint names
the ones that have bitten (the password hashers' strHash); it cannot know every
std signature. The bare-metal build — gopher-metal's `zig build gopher` — is
the check that sees them all, and this lint is the fast, local subset.

WHY IT EXISTS. Every rule here was a compile error on the bare-metal target
first, found one at a time, each hiding behind the last: twenty-one bare
`std.Io` signatures, then six `std.Io.Dir`/`.Clock` spellings, then a single
default value — `mem_meter`'s child defaulted to page_allocator — that dragged
`std.posix` into the whole route table. The lint makes the next one a build
failure here rather than an afternoon there.

Run by ops/check_zig; tested by tools/test_lint_portable.py. Comment text is
ignored (only the code before `//` is checked), so prose may name any of this.
"""
import os
import re
import sys
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zig_source  # noqa: E402  the one reading of a source file the lints share

ROOT_MODULE = "router.zig"
# The roots the real tree is checked from: the route table, and the webbox
# library. Both must be there.
LIBRARY_ROOT = "webbox.zig"
ROOTS = (ROOT_MODULE, LIBRARY_ROOT)
# The named modules a portable file may import that are files here, and the
# file each is: the closure follows them.
MODULE_FILES = {"webbox": LIBRARY_ROOT}
# The library's Linux half, its own module (`webbox_linux`), and its files: a
# site served as a Linux process, which only a Linux `main` imports. Any
# portable file reaching one is a finding; the closure stops there.
HOST_MODULES = frozenset({"webbox_linux"})
HOST_ONLY = frozenset({"webbox_linux.zig", "linux_host.zig", "bind.zig", "linux_config.zig"})


# (pattern, advice). Checked in order; one finding per match.
# The Store's seam: what may call Io.Dir.cwd(). Checked in every reached file
# but this one.
STORE = "store.zig"
CWD = (re.compile(r"\bIo\.Dir\.cwd\s*\("),
       "the disk is the Store's: call store.zig (read, write, list, stat...) — it keeps FAT's rules on every host")

RULES = [
    # The host's seam.
    (re.compile(r"\bstd\.Io\.(Dir|Clock|Mutex|Group)\b"),
     "spell it Io.{0}, with Io from host_io: the build chooses the host there"),
    (re.compile(r"\bstd\.Io\b(?!\s*\.)"),
     'take it from host_io (const Io = @import("host_io").Io;): the build chooses the host there'),
    # The host.
    (re.compile(r"\bstd\.Io\.(Threaded|net)\b"),
     "std.Io.{0} is the host's thread pool / sockets"),
    (re.compile(r"\bstd\.heap\.(page_allocator|c_allocator|raw_c_allocator|smp_allocator)\b"),
     "std.heap.{0} is a host allocator — take an allocator from the host instead"),
    (re.compile(r"\bstd\.(process|posix|Thread)\b"),
     "std.{0} is the host"),
    (re.compile(r"\bstd\.os\."),
     "std.os is the host"),
    (re.compile(r"\bstd\.c\."),
     "std.c is libc"),
    (re.compile(r"\bstd\.time\.(timestamp|milliTimestamp|microTimestamp|nanoTimestamp|Timer|Instant)\b"),
     "std.time.{0} reads the host clock — use Io.Clock.now(.real, io)"),
    (re.compile(r"\bstd\.crypto\.random\b"),
     "std.crypto.random is a getrandom syscall — take io.random"),
    (re.compile(r"\bstd\.fs\.(?!path\b)([A-Za-z_]+)"),
     "std.fs.{0} is the old host file API — use Io.Dir"),
    (re.compile(r"\bstd\.debug\.print\b"),
     "std.debug.print writes the host's stderr"),
    # std functions that take a REAL std.Io. Our `io` is only std.Io where the
    # alias happens to be std's, so passing it compiles on Linux and nowhere
    # else. The password hashers draw their salt through it.
    (re.compile(r"\b(?:bcrypt|scrypt|argon2|pwhash\.[a-z0-9]+)\.strHash\s*\("),
     "strHash takes a real std.Io — draw the salt with io.random and call strHashWithSalt"),
]


def code(line: str) -> str:
    """The part of a line before any comment (`//!` and `///` too), literals
    kept whole: zig_source.code."""
    return zig_source.code(line)


def test_lines(lines):
    """The 1-based line numbers inside a `test {}` block.

    Braces inside string and character literals, and in a multi-line
    `\\\\` string, are not counted (zig_source.blank), so a test whose body
    prints "{" or compares a character with '{' does not end early.
    """
    inside, depth, out = False, 0, set()
    for n, line in enumerate(lines, 1):
        c = code(line)
        if not inside and depth == 0 and re.match(r"\s*test\b", c):
            inside = True
        if inside:
            out.add(n)
        for ch in zig_source.blank(line):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth <= 0:
                    depth = 0
                    inside = False
    return out


TOP_DECL = re.compile(r"^(?:(pub)\s+)?(?:inline\s+)?(?:fn\s+([A-Za-z_]\w*)\s*\(|(?:const|var)\s+([A-Za-z_]\w*)\b)")


def test_only_lines(lines, tests):
    """The 1-based lines of private top-level declarations that only tests
    use: a test fixture or helper written outside a `test {}` block.

    A declaration is test-only when its name appears, outside its own body,
    on at least one test line (or in another test-only declaration), and
    nowhere else. Found by repeating until nothing more is found. One that
    nothing names is checked like any other, and so is a `pub` one: another
    file may name it.
    """
    decls = []  # (name, first, last)
    depth, current = 0, None
    for n, line in enumerate(lines, 1):
        c = code(line)
        if depth == 0 and n not in tests:
            m = TOP_DECL.match(c)
            if m and not m.group(1):
                current = [m.group(2) or m.group(3), n, n]
        for ch in zig_source.blank(line):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth = max(0, depth - 1)
        if current:
            current[2] = n
            if depth == 0 and (c.rstrip().endswith(";") or c.rstrip().endswith("}")):
                decls.append(tuple(current))
                current = None
    only = set()
    changed = True
    while changed:
        changed = False
        for name, first, last in decls:
            if (first, last) in only:
                continue
            word = re.compile(r"\b" + re.escape(name) + r"\b")
            used_elsewhere, used_by_tests = False, False
            for n, line in enumerate(lines, 1):
                if first <= n <= last or not word.search(code(line)):
                    continue
                if n in tests or any(a <= n <= b for a, b in only):
                    used_by_tests = True
                else:
                    used_elsewhere = True
                    break
            if used_by_tests and not used_elsewhere:
                only.add((first, last))
                changed = True
    return {n for a, b in only for n in range(a, b + 1)}


def library_files(src_dir: str):
    """The library's portable files: webbox.zig and the files it names. Empty
    in a tree without a library."""
    path = os.path.join(src_dir, LIBRARY_ROOT)
    if not os.path.isfile(path):
        return set()
    with open(path, encoding="utf-8") as f:
        return {LIBRARY_ROOT} | set(zig_source.imports(f.read()))


def deps_of(text):
    """What a file imports that is a file here: by path, and the `webbox`
    module as webbox.zig."""
    return zig_source.imports(text) + [MODULE_FILES[m] for m in zig_source.modules(text) if m in MODULE_FILES]


def closure(src_dir: str, root=ROOT_MODULE):
    """Every local .zig file reachable from `root` (a name, or several) by
    @import, the roots included: by path, and through the `webbox` module.

    Other named modules (`@import("std")`, `@import("build_options")`) and
    embedded assets are not files in src_dir and are not followed; nor is the
    library's Linux half, which is a finding. A cycle terminates.
    """
    roots = (root,) if isinstance(root, str) else tuple(root)
    for r in roots:
        start = os.path.join(src_dir, r)
        if not os.path.isfile(start):
            raise FileNotFoundError(f"the root {r} is not at {start}")
    seen, todo = set(), deque(roots)
    while todo:
        name = todo.popleft()
        if name in seen:
            continue
        path = os.path.join(src_dir, name)
        if not os.path.isfile(path):
            continue  # a dangling import is zig's error to report, not ours
        seen.add(name)
        with open(path, encoding="utf-8") as f:
            for dep in deps_of(f.read()):
                if os.path.basename(dep) in HOST_ONLY:
                    continue  # the Linux half: a finding (scan), not followed
                if dep not in seen:
                    todo.append(dep)
    return seen


def scan(src_dir: str, root=ROOT_MODULE):
    """Findings as (file, line, text, advice), in file then line order."""
    found = []
    library = library_files(src_dir)
    for name in sorted(closure(src_dir, root)):
        with open(os.path.join(src_dir, name), encoding="utf-8") as f:
            text = f.read()
        for m in zig_source.modules(text):
            if m in HOST_MODULES:
                found.append((name, 0, f'@import("{m}")',
                              f"{m} is the library's Linux half: only a Linux main imports it"))
        for dep in zig_source.imports(text):
            base = os.path.basename(dep)
            if base in HOST_ONLY:
                found.append((name, 0, f'@import("{dep}")',
                              f"{base} is the library's Linux half: only a Linux main reaches it, through the webbox_linux module"))
            elif name not in library and base in library:
                found.append((name, 0, f'@import("{dep}")',
                              f'import the library as its module: @import("webbox"){"" if base == LIBRARY_ROOT else "." + base[:-4]}'))
        with open(os.path.join(src_dir, name), encoding="utf-8") as f:
            lines = f.readlines()
        tests = test_lines(lines)
        tests |= test_only_lines(lines, tests)
        rules = RULES if name == STORE else RULES + [CWD]
        for n, line in enumerate(lines, 1):
            if n in tests:
                continue
            c = code(line)
            for pattern, advice in rules:
                for m in pattern.finditer(c):
                    arg = m.group(1) if m.groups() else ""
                    found.append((name, n, m.group(0), advice.format(arg)))
    return found


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.normpath(os.path.join(here, "..", "zig-server", "src"))
    reach = closure(src, ROOTS)
    found = scan(src, ROOTS)
    if not found:
        print(f"portable lint: the {len(reach)} modules the route table and the webbox library reach stay off the host")
        return 0

    print("portable lint FAILED — the route table reaches the host here, "
          "which will not compile on a machine with no operating system:", file=sys.stderr)
    for name, n, text, advice in found:
        print(f"  {name}:{n}: {text} — {advice}", file=sys.stderr)
    print("\nSee tools/lint_portable.py for what is allowed and why.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
