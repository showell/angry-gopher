#!/usr/bin/env python3
"""Poka-yoke lint: nothing the route table reaches may reach for the host.

`zig-server/src/router.zig` is WHAT THIS SITE SERVES, and it is deliberately
separate from `server.zig`, which is HOW THIS PROCESS STARTS. The point of the
split is that the route table can be called by a host that is not Linux:
gopher-metal boots it on a machine with no operating system. That only works if
every module the route table transitively imports stays off the host — and a
module that does not is not a slower path there. It FAILS TO COMPILE.

This lint computes that set from the import graph, starting at router.zig, and
checks every file in it. A module outside the set (server.zig, config.zig, the
stress harness, the markdown tools) is host-side by definition and is not
checked. There is no hardcoded list of exemptions to fall out of date.

WHAT IT FORBIDS, inside the set and outside `test {}` blocks:

  THE PORTING SEAM   Every file opens with `const Io = std.Io;`, and gopher-metal
                     rewrites exactly that line. So `std.Io.Dir`, `.Clock`,
                     `.Mutex` and `.Group` — the namespaces that machine
                     replaces — must be spelled through the alias, and so must a
                     bare `std.Io` in a signature. Spelled `std.` they are
                     unreachable by the port, and `std.Io.Dir.cwd()` reaches for
                     `std.posix.AT.FDCWD`.
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

ROOT_MODULE = "router.zig"

IMPORT = re.compile(r'@import\("([A-Za-z0-9_]+\.zig)"\)')

# (pattern, advice). Checked in order; one finding per match.
# The Store's seam: what may call Io.Dir.cwd(). Checked in every reached file
# but this one.
STORE = "store.zig"
CWD = (re.compile(r"\bIo\.Dir\.cwd\s*\("),
       "the disk is the Store's: call store.zig (read, write, list, stat...) — it keeps FAT's rules on every host")

# **THE REQUEST'S DOOR** (request.zig, Steve 2026-10-07): only request.zig
# names zig's server request, and only the edge reaches under the door.
REQUEST_DOOR = "request.zig"
EDGE = {"request.zig", "http.zig", "edge.zig", "router.zig"}
RAW_TYPE = (re.compile(r"\bstd\.http\.Server\.Request\b"),
            "a handler takes request.zig's Request: zig's server request is the host's, behind the door")
RAW_REACH = (re.compile(r"\breq\.raw\b"),
             "the host's request is the edge's (http.zig, edge.zig, router.zig): add what you need to request.zig")

RULES = [
    # The porting seam.
    (re.compile(r"\bstd\.Io\.(Dir|Clock|Mutex|Group)\b"),
     "spell it Io.{0} — the alias is what the port rewrites"),
    (re.compile(r"\bstd\.Io\b(?!\s*\.)"),
     "spell it Io — the alias is what the port rewrites"),
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
    """The part of a line before any comment. `//!` and `///` count too.

    A `//` inside a string literal would cut the line short; that can only
    HIDE a finding after it on the same line, never invent one.
    """
    at = line.find("//")
    return line if at < 0 else line[:at]


def test_lines(lines):
    """The 1-based line numbers inside a `test {}` block.

    Braces inside double-quoted strings are skipped, so a test whose body
    prints "{" does not end early. Multi-line `\\\\` string literals carry no
    quotes, and their braces are counted — zig test bodies here do not put
    unbalanced braces in them.
    """
    inside, depth, out = False, 0, set()
    for n, line in enumerate(lines, 1):
        c = code(line)
        if not inside and depth == 0 and re.match(r"\s*test\b", c):
            inside = True
        if inside:
            out.add(n)
        in_str = False
        prev = ""
        for ch in c:
            if ch == '"' and prev != "\\":
                in_str = not in_str
            elif not in_str and ch == "{":
                depth += 1
            elif not in_str and ch == "}":
                depth -= 1
                if depth <= 0:
                    depth = 0
                    inside = False
            prev = ch
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
        in_str, prev = False, ""
        for ch in c:
            if ch == '"' and prev != "\\":
                in_str = not in_str
            elif not in_str and ch == "{":
                depth += 1
            elif not in_str and ch == "}":
                depth = max(0, depth - 1)
            prev = ch
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


def closure(src_dir: str, root: str = ROOT_MODULE):
    """Every local .zig file reachable from `root` by @import, root included.

    Named modules (`@import("std")`, `@import("build_options")`) and embedded
    assets are not files in src_dir and are not followed. A cycle terminates.
    """
    start = os.path.join(src_dir, root)
    if not os.path.isfile(start):
        raise FileNotFoundError(f"the route table is not at {start}")
    seen, todo = set(), deque([root])
    while todo:
        name = todo.popleft()
        if name in seen:
            continue
        path = os.path.join(src_dir, name)
        if not os.path.isfile(path):
            continue  # a dangling import is zig's error to report, not ours
        seen.add(name)
        with open(path, encoding="utf-8") as f:
            for line in f:
                for dep in IMPORT.findall(code(line)):
                    if dep not in seen:
                        todo.append(dep)
    return seen


def scan(src_dir: str, root: str = ROOT_MODULE):
    """Findings as (file, line, text, advice), in file then line order."""
    found = []
    for name in sorted(closure(src_dir, root)):
        with open(os.path.join(src_dir, name), encoding="utf-8") as f:
            lines = f.readlines()
        tests = test_lines(lines)
        tests |= test_only_lines(lines, tests)
        rules = RULES if name == STORE else RULES + [CWD]
        if name != REQUEST_DOOR:
            rules = rules + [RAW_TYPE]
        if name not in EDGE:
            rules = rules + [RAW_REACH]
        for n, line in enumerate(lines, 1):
            if n in tests:
                continue
            c = code(line)
            if re.search(r"\bconst\s+Io\s*=\s*std\.Io\s*;", c):
                c = re.sub(r"\bconst\s+Io\s*=\s*std\.Io\s*;", "", c)  # the alias itself
            for pattern, advice in rules:
                for m in pattern.finditer(c):
                    arg = m.group(1) if m.groups() else ""
                    found.append((name, n, m.group(0), advice.format(arg)))
    return found


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.normpath(os.path.join(here, "..", "zig-server", "src"))
    reach = closure(src)
    found = scan(src)
    if not found:
        print(f"portable lint: the {len(reach)} modules the route table reaches stay off the host")
        return 0

    print("portable lint FAILED — the route table reaches the host here, "
          "which will not compile on a machine with no operating system:", file=sys.stderr)
    for name, n, text, advice in found:
        print(f"  {name}:{n}: {text} — {advice}", file=sys.stderr)
    print("\nSee tools/lint_portable.py for what is allowed and why.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
