#!/usr/bin/env python3
"""Poka-yoke lint: a failure to read the store is not the store saying "none".

Four store reads turned an error into "", 0 or null in one week (ef3091eb):
an unreadable transcript counted no messages and the next was glued onto the
last; an unreadable doc opened empty and its next save replaced it; an
unreadable game log resumed as a new game; an unreadable upload total gave a
user their allowance again. Each was a read whose error was caught into a
value, so a disk that failed looked exactly like a file that was not there.

WHAT IT REFUSES, in every zig-server/src file but store.zig and outside
`test {}` blocks and the helpers only tests use: a call of one of the store's
reads (`read`, `readOrEmpty`, `readOrNull`, `readAt`, `stat`, `statOrNull`,
`has`, `list`), under whatever name the file gives store.zig, or of any
function that reads the store, directly or through others (`readers`,
computed on every run: users.isMember was such a wrapper, metal-vmm QUEUE
114), followed by a `catch` that makes its error a value without naming
it: `catch ""`, `catch return 0`, `catch null`, `catch {}`, `catch continue`,
`catch |_| ...`, a named `catch |e|` whose handler never passes `e` on, or
passes some failures on and makes another one but absence a value (`switch
(e) { error.AccessDenied => null, else => return e }`), and the like; or an
`if (read) |v| ... else |_| ...`, or an `else |e|` that does any of that,
which drops it the same way (counter.zig's `next` read an unreadable counter
as a new one, and handed out ids already given). Absence is what store.zig
reads as "not there": FileNotFound, NotDir, NameTooLong.

WHAT IT LETS PASS:

  catch |e| ... e ...           the error is named and passed on (`return e`,
                                an arm `=> e`, another error returned in its
                                place), absence alone made a value
                                (`error.FileNotFound => ""`). The same after
                                `else |e|`.
  try, catch unreachable,       the failure goes on, or stops the program.
  catch @panic(...)
  `// absent-ok: <why>` on      the failure may be read so there, and the
  the line before the call      marker says why (as gopher-metal presumes an
                                omitted flush a bug unless a comment defends
                                it). Any other comment defends nothing.
  the store's writes            a write whose failure is swallowed is another
                                question: this lint is about absence.

A WRAPPER'S OWN ERRORS: an arm that names an error a wrapper has of its own
(`error.NoSuchMessage => return badRequest(...)`) has looked at it; only a
wrapper's catch-all is held to absence. A failure answered as a server error
(`.internal_server_error`) is told, not read as absence, for any call.

WHAT IT CANNOT SEE: a method reached through a value (`x.f()`): only a
file's top-level functions are followed, by their bare name in their own
file and by `alias.f` elsewhere. Comment text and string contents are
ignored.

Run by ops/check_zig; tested by tools/test_lint_store_absence.py.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lint_portable import test_lines, test_only_lines  # noqa: E402

STORE = "store.zig"
READS = ("read", "readOrEmpty", "readOrNull", "readAt", "stat", "statOrNull", "has", "list")
ALIAS = re.compile(r'\bconst\s+([A-Za-z_]\w*)\s*=\s*@import\("store\.zig"\)')
IMPORT = re.compile(r'\bconst\s+([A-Za-z_]\w*)\s*=\s*@import\("([\w.]+\.zig)"\)')
FN = re.compile(r"^\s*(?:pub\s+)?(?:inline\s+)?fn\s+([A-Za-z_]\w*)\s*\(")


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


DEFENCE = re.compile(r"^\s*//\s*absent-ok:\s*\S")


def defended(lines, n: int) -> bool:
    """Whether the line before line `n` says, with the marker, why the
    failure may be read so: `// absent-ok: <why>`."""
    return n >= 2 and bool(DEFENCE.match(lines[n - 2]))


def handler_of(rest: str) -> str:
    """The handler after `catch |e|`: up to the end of its statement, or the
    `,` or `)` that closes what holds it, at the handler's own depth."""
    depth, at = 0, 0
    while at < len(rest):
        ch = rest[at]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch in ";," and depth == 0:
            break
        at += 1
    return rest[:at]


def passes_on(handler: str, name: str) -> bool:
    """Whether a handler hands its named error on: `return e`, an arm that
    is `=> e` or `=> return e`, or `e` itself."""
    e = re.escape(name)
    return bool(re.search(r"\breturn\s+" + e + r"\b", handler) or
                re.search(r"=>\s*" + e + r"\s*(?:[,}]|$)", handler) or
                handler.strip() == name)


# What the store itself reads as "not there" (store.zig's readOrNull,
# statOrNull, has): the only failures a handler may make a value of.
ABSENT = ("FileNotFound", "NotDir", "NameTooLong")


def braced(text: str) -> str:
    """What is inside the `{...}` that `text` starts with."""
    depth = 0
    for at, ch in enumerate(text):
        depth += {"{": 1, "}": -1}.get(ch, 0)
        if depth == 0:
            return text[1:at]
    return text[1:]


def arms(body: str):
    """A switch's arms, as (pattern, what it does), from inside its braces."""
    out, at = [], 0
    while at < len(body):
        arrow = body.find("=>", at)
        if arrow < 0:
            break
        depth, end = 0, arrow + 2
        while end < len(body):
            ch = body[end]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            elif ch == "," and depth == 0:
                break
            end += 1
        out.append((body[at:arrow].strip(), body[arrow + 2:end].strip()))
        at = end + 1
    return out


ANSWERED = re.compile(r"\.(?:internal_server_error|service_unavailable)\b|\.status\s*=\s*5\d\d\b")


def answered(does: str) -> bool:
    """Whether a handler answers the request as a server error: the client
    is told it failed, which is no file that is not there."""
    return bool(ANSWERED.search(does))


def fails_still(does: str, names) -> bool:
    """Whether an arm (or a branch) leaves the failure a failure: the error
    passed on, another error returned in its place, the request answered as
    a server error, or the program stopped."""
    does = does.strip()
    if does.startswith("|"):  # `else => |other| ...`: another name for it
        names = list(names) + [does[1:does.find("|", 1)].strip()]
        does = does[does.find("|", 1) + 1:].strip()
    return (any(passes_on(does, n) for n in names) or
            bool(re.match(r"return\s+(?:error|[A-Z]\w*)\.\w+", does)) or answered(does) or
            does.startswith("unreachable") or does.startswith("@panic"))


def only_absence(pattern: str, wrapper: bool = False) -> bool:
    """Whether a switch arm's pattern names absence and nothing else. Of a
    wrapper (`readers`), any error it names: a wrapper has errors of its own
    (reactions' `NoSuchMessage`), and an arm that names one has looked at
    it. Only a catch-all (`else`) is held to absence there."""
    items = [i.strip() for i in pattern.split(",") if i.strip()]
    one = r"error\.\w+" if wrapper else r"error\.(?:" + "|".join(ABSENT) + r")"
    return bool(items) and all(re.fullmatch(one, i) for i in items)


def handler_keeps(handler: str, name: str, wrapper: bool = False) -> bool:
    """Whether a handler of a named error keeps every failure but absence a
    failure (metal-vmm QUEUE 117): a switch on it whose every arm either
    passes the failure on or names absence alone; an `if (e == error.X)`
    whose X is absence, the rest passed on; or any other handler that
    passes it on."""
    h = handler.strip()
    e = re.escape(name)
    m = re.match(r"switch\s*\(\s*" + e + r"\s*\)\s*", h)
    if m and h[m.end():].startswith("{"):
        return all(fails_still(does, [name]) or only_absence(pattern, wrapper)
                   for pattern, does in arms(braced(h[m.end():])))
    m = re.match(r"if\s*\(\s*" + e + r"\s*==\s*error\.(\w+)\s*\)", h)
    if m:
        otherwise = re.search(r"\belse\b(.*)$", h[m.end():], re.S)
        return (m.group(1) in ABSENT or wrapper) and otherwise is not None and fails_still(otherwise.group(1), [name])
    return passes_on(h, name) or answered(h)


def dropped_by_else(rest: str, wrapper: bool = False) -> bool:
    """After the call in `if (call) |v| body else |e| ...`: whether its error
    is dropped there, by `else |_|`, or by a named `else |e|` whose handler
    makes a failure but absence a value (metal-vmm QUEUE 117). `rest`
    starts just past the call's `)`."""
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
    m = re.match(r"\|\s*(\w+)\s*\|", rest)
    if not m:
        return False
    return m.group(1) == "_" or not handler_keeps(handler_of(rest[m.end():]), m.group(1), wrapper)


def imports(lines):
    """{alias: file} for each `const x = @import("y.zig")`, read from the
    lines themselves: blanking empties the strings."""
    return {m.group(1): m.group(2) for l in lines for m in IMPORT.finditer(l.split("//")[0])}


def functions(lines):
    """{name: body} for each function at a file's top level, outside tests,
    its body as blanked code. A method in a struct is not here: a call of
    one through a value (`x.f()`) names no file this could follow."""
    tests = test_lines(lines)
    tests |= test_only_lines(lines, tests)
    out, current, depth = {}, None, 0
    for n, line in enumerate(lines, 1):
        c = blank(line)
        m = FN.match(c)
        if m and depth == 0 and n not in tests:
            current = m.group(1)
            out[current] = ""
        if current is not None:
            out[current] += c
        depth += c.count("{") - c.count("}")
        if depth == 0 and current is not None and "{" in out[current]:
            current = None
    return out


def readers(files):
    """**THE FUNCTIONS THAT READ THE STORE, DIRECTLY OR THROUGH OTHERS**
    (metal-vmm QUEUE 114), as {(file, name)}, from `files` ({name: lines}):
    computed on every run, so a new wrapper is followed without anyone
    listing it. users.isMember was one the lint could not see."""
    bodies = {(f, fn): body for f, lines in files.items() if f != STORE for fn, body in functions(lines).items()}
    found = set()
    for (f, fn), body in bodies.items():
        aliases = [a for a, target in imports(files[f]).items() if target == STORE]
        if aliases and re.search(r"\b(?:" + "|".join(aliases) + r")\.(?:" + "|".join(READS) + r")\s*\(", body):
            found.add((f, fn))
    # Each body's calls, once: (alias or None, name). Then the fixed point is
    # over that graph, not the text.
    call = re.compile(r"(?<![\w.])(?:([A-Za-z_]\w*)\.)?([A-Za-z_]\w*)\s*\(")
    mods = {f: imports(lines) for f, lines in files.items()}
    edges = {}
    for (f, fn), body in bodies.items():
        targets = set()
        for m in call.finditer(body):
            alias, callee = m.group(1), m.group(2)
            if alias is None:
                if not re.search(r"\bfn\s+$", body[:m.start()]):
                    targets.add((f, callee))
            elif alias in mods[f]:
                targets.add((mods[f][alias], callee))
        edges[(f, fn)] = targets
    grew = True
    while grew:
        grew = False
        for key, targets in edges.items():
            if key not in found and targets & found:
                found.add(key)
                grew = True
    return found


def calls_of(found, f, lines):
    """(pattern, label) for a call, from file `f`, of each function in
    `found`: by its bare name in its own file, by `alias.name` elsewhere."""
    mods = imports(lines)
    out = []
    for rf, rfn in sorted(found):
        if rf == f:
            out.append((r"(?<![\w.])(?<!fn )" + re.escape(rfn) + r"\s*\(", rfn))
        for a, target in mods.items():
            if target == rf:
                out.append((r"(?<![\w.])" + re.escape(a) + r"\." + re.escape(rfn) + r"\s*\(", f"{a}.{rfn}"))
    return out


def findings(name: str, lines, found=frozenset()):
    """(line, text) for each read whose failure is caught into a value: a
    read of the store, or a call of a function in `found` (`readers`)."""
    tests = test_lines(lines)
    tests |= test_only_lines(lines, tests)  # a test's own helper
    code = [blank(l) for l in lines]
    # Read from the lines themselves: blanking empties "store.zig" too.
    aliases = {m.group(1) for l in lines for m in ALIAS.finditer(l.split("//")[0])}
    wrappers = calls_of(found, name, lines)
    if not aliases and not wrappers:
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

    patterns = [(r"\b(?:" + "|".join(map(re.escape, sorted(aliases))) + r")\.(?:" + "|".join(READS) + r")\s*\(", None)] if aliases else []
    patterns += wrappers
    sites = []
    for pattern, label in patterns:
        for m in re.finditer(pattern, text):
            what = label or m.group(0).rstrip("( \t\n")
            sites.append((m, what + ("(...), which reads the store," if label else "(...)"), label is not None))
    sites.sort(key=lambda s: s[0].start())
    out = []
    for m, what, wrapper in sites:
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
        if re.search(r"\bif\s*\(\s*$", text[:m.start()]) and rest.startswith(")"):
            # `if (call) |v| ... else |e| ...`; an `if (call() catch v)` is a
            # catch like any other, below.
            if dropped_by_else(rest, wrapper):
                if not defended(lines, n):
                    out.append((n, f"if ({what}) ... else |...| that makes a failure a value"))
            continue
        if not re.match(r"catch\b", rest):
            continue
        handler = rest[len("catch"):].lstrip()
        if handler.startswith("|"):
            name = handler[1:handler.find("|", 1)].strip()
            if name != "_" and handler_keeps(handler_of(handler[handler.find("|", 1) + 1:]), name, wrapper):
                continue  # named, and passed on: absence alone is the handler's to make a value
        elif handler.startswith("unreachable") or handler.startswith("@panic") or answered(handler_of(handler)):
            continue
        if defended(lines, n):
            continue
        out.append((n, f"{what} catch {handler.split(chr(10))[0].strip()}"))
    return out


def scan(src_dir: str):
    """Findings as (file, line, text), in file then line order."""
    files = {}
    for name in sorted(os.listdir(src_dir)):
        if name.endswith(".zig"):
            with open(os.path.join(src_dir, name), encoding="utf-8") as f:
                files[name] = f.readlines()
    reading = readers(files)
    found = []
    for name, lines in files.items():
        if name != STORE:
            found += [(name, n, t) for n, t in findings(name, lines, reading)]
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
