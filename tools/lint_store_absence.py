#!/usr/bin/env python3
"""Poka-yoke lint: a failure to read the store is not the store saying "none".

Four store reads turned an error into "", 0 or null in one week (ef3091eb):
an unreadable transcript counted no messages and the next was glued onto the
last; an unreadable doc opened empty and its next save replaced it; an
unreadable game log resumed as a new game; an unreadable upload total gave a
user their allowance again. Each was a read whose error was caught into a
value, so a disk that failed looked exactly like a file that was not there.

WHAT IT REFUSES, in every zig-server/src file but store.zig and outside
`test {}` blocks and the helpers only tests use: a call of one of the store's reads (`read`, `readOrEmpty`,
`readAt`, `stat`, `has`, `list`), under whatever name the file gives
store.zig, followed by a `catch` that makes its error a value without naming
it: `catch ""`, `catch return 0`, `catch null`, `catch {}`, `catch continue`,
`catch |_| ...` and the like; or an `if (read) |v| ... else |_| ...`, which
drops it the same way (counter.zig's `next` read an unreadable counter as a
new one, and handed out ids already given).

WHAT IT LETS PASS:

  catch |e| ...                 the error is named, and the handler says what
                                each one means (`error.FileNotFound => ""`).
  try, catch unreachable,       the failure goes on, or stops the program.
  catch @panic(...)
  a `//` comment on the line    the failure may be read so there, and the
  before the call               comment says why (as gopher-metal presumes an
                                omitted flush a bug unless a comment defends it).
  the store's writes            a write whose failure is swallowed is another
                                question: this lint is about absence.

WHAT IT CANNOT SEE: a read reached through a wrapper (a module's own function
that calls the store and is then caught into a value). Comment text and
string contents are ignored.

Run by ops/check_zig; tested by tools/test_lint_store_absence.py.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lint_portable import test_lines, test_only_lines  # noqa: E402

STORE = "store.zig"
READS = ("read", "readOrEmpty", "readAt", "stat", "has", "list")
ALIAS = re.compile(r'\bconst\s+([A-Za-z_]\w*)\s*=\s*@import\("store\.zig"\)')


def blank(line: str) -> str:
    """The line with its comment gone and every string's contents spaces, so
    neither can hold a call. The quotes stay: `catch ""` is still `""`."""
    out, in_str, i = [], False, 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\" and i + 1 < len(line):
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_str = False
                out.append(ch)
            else:
                out.append(" " if ch != "\n" else ch)
        elif ch == '"':
            in_str = True
            out.append(ch)
        elif line.startswith("//", i):
            out.append("\n" if line.endswith("\n") else "")
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def dropped_by_else(rest: str) -> bool:
    """After the call in `if (call) |v| body else |_| ...`: whether its error
    goes to an `else |_|`. `rest` starts just past the call's `)`."""
    if not rest.startswith(")"):
        return False
    rest = rest[1:].lstrip()
    if rest.startswith("|"):
        rest = rest[rest.find("|", 1) + 1:].lstrip()
    if rest.startswith("{"):
        depth, at = 0, 0
        while at < len(rest):
            depth += {"{": 1, "}": -1}.get(rest[at], 0)
            if depth == 0:
                break
            at += 1
        rest = rest[at + 1:]
    else:
        depth, at = 0, 0
        while at < len(rest) and rest[at] != ";":
            depth += {"(": 1, ")": -1, "{": 1, "}": -1}.get(rest[at], 0)
            if depth == 0 and re.match(r"\belse\b", rest[at:]) and (at == 0 or not rest[at - 1].isalnum()):
                break
            at += 1
        rest = rest[at:]
    rest = rest.lstrip()
    if not re.match(r"else\b", rest):
        return False
    rest = rest[len("else"):].lstrip()
    return bool(re.match(r"\|\s*_\s*\|", rest))


def findings(name: str, lines):
    """(line, text) for each read whose failure is caught into a value."""
    tests = test_lines(lines)
    tests |= test_only_lines(lines, tests)  # a test's own helper
    code = [blank(l) for l in lines]
    # Read from the lines themselves: blanking empties "store.zig" too.
    aliases = {m.group(1) for l in lines for m in ALIAS.finditer(l.split("//")[0])}
    if not aliases:
        return []
    text = "".join(c if c.endswith("\n") else c + "\n" for c in code)
    starts = [0]
    for c in code:
        starts.append(starts[-1] + len(c if c.endswith("\n") else c + "\n"))

    def line_of(at):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= at:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    call = re.compile(r"\b(" + "|".join(map(re.escape, sorted(aliases))) + r")\.(" + "|".join(READS) + r")\s*\(")
    out = []
    for m in call.finditer(text):
        n = line_of(m.start())
        if n in tests:
            continue
        depth, at = 0, m.end() - 1
        while at < len(text):
            if text[at] == "(":
                depth += 1
            elif text[at] == ")":
                depth -= 1
                if depth == 0:
                    break
            at += 1
        rest = text[at + 1:].lstrip()
        if re.search(r"\bif\s*\(\s*$", text[:m.start()]):
            if dropped_by_else(rest):
                if not (n >= 2 and lines[n - 2].strip().startswith("//")):
                    out.append((n, f"if ({m.group(1)}.{m.group(2)}(...)) ... else |_|"))
            continue
        if not re.match(r"catch\b", rest):
            continue
        handler = rest[len("catch"):].lstrip()
        if handler.startswith("|"):
            if handler[1:handler.find("|", 1)].strip() != "_":
                continue  # named: the handler judges each error
        elif handler.startswith("unreachable") or handler.startswith("@panic"):
            continue
        if n >= 2 and lines[n - 2].strip().startswith("//"):
            continue  # defended
        out.append((n, f"{m.group(1)}.{m.group(2)}(...) catch {handler.split(chr(10))[0].strip()}"))
    return out


def scan(src_dir: str):
    """Findings as (file, line, text), in file then line order."""
    found = []
    for name in sorted(os.listdir(src_dir)):
        if not name.endswith(".zig") or name == STORE:
            continue
        with open(os.path.join(src_dir, name), encoding="utf-8") as f:
            lines = f.readlines()
        found += [(name, n, t) for n, t in findings(name, lines)]
    return found


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.normpath(os.path.join(here, "..", "zig-server", "src"))
    found = scan(src)
    if not found:
        print("store-absence lint: no read of the store makes its failure a value without saying why")
        return 0
    print("store-absence lint FAILED — a read of the store whose failure is caught into a value, "
          "so a disk that failed looks like a file that is not there:", file=sys.stderr)
    for name, n, text in found:
        print(f"  {name}:{n}: {text}", file=sys.stderr)
    print("\nName the error (`catch |e| switch (e) { error.FileNotFound => ..., else => return e }`),"
          " or say on the line before why its failure may be read so. See tools/lint_store_absence.py.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
