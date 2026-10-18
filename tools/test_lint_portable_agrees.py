"""Until the switch: tools/lint_portable.shale says what tools/lint_portable.py
says (metal-vmm QUEUE 238). Deleted with the Python, in the commit that
wires the Shale lint into ops/check_zig.

Two trees. The real one: the same findings (none), and the Shale's set is
the Python's plus shale/src/script/*.zig, the files the Python never read
(it resolved script/script.zig's imports from the tree's top, where they
are not). And a copy of it with a line per rule planted in router.zig: the
same findings, line for line, advice and all, but for a planted string:
the Python finds std.Io and std.heap.page_allocator in it, the Shale
rightly nothing.

    python3 angry-gopher/tools/test_lint_portable_agrees.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lint_portable  # noqa: E402
import zig_source  # noqa: E402

REPO = os.path.dirname(HERE)
PARENT = os.path.dirname(REPO)
NAME = os.path.basename(REPO)
SCRIPT = os.path.join(HERE, "lint_portable.shale")
BUDGET = ["--budget", "steps=500000000", "--budget", "arena_bytes=1073741824"]

PLANT = """
const p_dir = std.Io.Dir;
fn pBare(io: std.Io) void { _ = io; }
const p_through = @import("std").Io.Dir;
const p_reader = @import("std").Io.Reader;
const p_threaded = std.Io.Threaded;
const p_heap = std.heap.page_allocator;
const p_fixed = std.heap.FixedBufferAllocator;
const p_process = std.process.exit;
const p_posix = std.posix.getpid;
const p_thread = std.Thread;
const p_os = std.os.linux;
const p_c = std.c.getpid;
fn pTime() i64 { return std.time.timestamp(); }
const p_ns = std.time.ns_per_s;
fn pRandom() void { std.crypto.random.bytes(&.{}); }
fn pCwd() void { _ = std.fs.cwd(); }
const p_path = std.fs.path.join;
fn pPrint() void { std.debug.print("x", .{}); }
fn pHash() void { _ = bcrypt.strHash(); _ = pwhash.argon2.strHash(); }
fn pIoCwd() void { _ = Io.Dir.cwd(); }
const p_string = "std.Io and std.heap.page_allocator";
// std.os.linux in a comment
const p_linux = @import("webbox_linux");
const p_by_path = @import("http.zig");
"""


def python(tree):
    found = lint_portable.scan(tree, lint_portable.ROOTS)
    return (sorted(lint_portable.closure(tree, lint_portable.ROOTS)),
            [f"{name}:{n}: {text} — {advice}" for name, n, text, advice in found])


def shale(parent, repo_name):
    out = subprocess.run(["shale", *BUDGET, SCRIPT, "list=1", f"repo={repo_name}"],
                         cwd=parent, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"the Shale lint stopped:\n{out.stdout}{out.stderr}")
    lines = out.stdout.splitlines()
    return ([l[len("module "):] for l in lines if l.startswith("module ")],
            [l[len("finding "):] for l in lines if l.startswith("finding ")])


def same(what, py, sh):
    if py != sh:
        raise SystemExit(f"{what}: the lints disagree\n  python: {py}\n  shale:  {sh}")


def main():
    py_set, py_found = python(zig_source.TREE)
    sh_set, sh_found = shale(PARENT, NAME)
    same("the real tree's findings", py_found, sh_found)
    missing = sorted(set(py_set) - set(sh_set))
    extra = sorted(set(sh_set) - set(py_set))
    same("modules the Python reads and the Shale does not", missing, [])
    unexplained = [m for m in extra if not (m.startswith("script/") and os.path.isfile(os.path.join(PARENT, "shale", "src", m)))]
    same("modules only the Shale reads, outside shale/src/script", unexplained, [])

    with tempfile.TemporaryDirectory() as tmp:
        for rel in (os.path.join(NAME, "zig-server", "src"), os.path.join("zig-webbox", "src"), os.path.join("shale", "src")):
            shutil.copytree(os.path.join(PARENT, rel), os.path.join(tmp, rel))
        router = os.path.join(tmp, NAME, "zig-server", "src", "router.zig")
        with open(router, "a", encoding="utf-8") as f:
            f.write(PLANT)
        tree = tuple(os.path.join(tmp, rel) for rel in (os.path.join(NAME, "zig-server", "src"), os.path.join("zig-webbox", "src"), os.path.join("shale", "src")))
        _, py_planted = python(tree)
        _, sh_planted = shale(tmp, NAME)
        # The one disagreement, and the Shale's is right: the Python reads
        # code inside a string literal (a token is not its text).
        string = next(n for n, line in enumerate(open(router, encoding="utf-8"), 1) if "p_string" in line)
        in_string = [f for f in py_planted if f.startswith(f"router.zig:{string}: ")]
        same("the Python's findings in the planted string", [f.split(" — ")[0] for f in in_string],
             [f"router.zig:{string}: std.Io", f"router.zig:{string}: std.heap.page_allocator"])
        same("the planted tree's findings, the string aside", [f for f in py_planted if f not in in_string], sh_planted)
        if len(sh_planted) < 19:
            raise SystemExit(f"the planted tree found only {len(sh_planted)}: {sh_planted}")

    print(f"portable lint: the Shale says what the Python says (the real tree: {len(sh_found)} findings, "
          f"{len(py_set)} modules and {len(extra)} more in shale/src/script; the planted tree: {len(sh_planted)} findings, "
          f"and the Python's {len(in_string)} in a string)")


if __name__ == "__main__":
    main()
