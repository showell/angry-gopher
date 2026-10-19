"""One reading of a Zig source file, for the lints that judge the tree.

The lints used to read imports with two regexes of their own, one line at a
time, and cut a line at the first `//`: an import split over lines (a form
`zig fmt` keeps) was invisible, a `"http://"` string hid the rest of its line,
and a `'{'` character literal threw off a count of braces. This reads a line
the way Zig does, as far as the lints need:

  code(line)    the line before its comment, string and character literals
                kept whole (a `//` inside one is not a comment). A line of a
                multi-line `\\\\` string literal is all literal.
  blank(line)   code(line) with every literal's contents blanked, for
                counting braces.
  imports(text) every `@import("x.zig")` in the file's code, however it is
                split over lines, in order.
  modules(text) every named module a file imports (`@import("webbox")`,
                `@import("std")`), likewise.
  embeds(text)  every `@embedFile("...")` likewise.

What it does not see: an import through a name (`const s = @import("std");
s.heap...`). The lints that care say so; the build of the port is the guard
there.
"""
import os
import re

# The tree the lints judge: the application's sources and the libraries',
# zig-webbox and shale, sibling checkouts (zig-server/build.zig.zon's
# dependencies). The three hold no file of the same name, so a lint reads
# them as one folder.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_SRC = os.path.join(_REPO, "zig-server", "src")
LIBRARY_SRC = os.path.normpath(os.path.join(_REPO, "..", "zig-webbox", "src"))
SHALE_SRC = os.path.normpath(os.path.join(_REPO, "..", "shale", "src"))
TREE = (APP_SRC, LIBRARY_SRC, SHALE_SRC)


def at(src, name):
    """Where `name` is in `src`: a folder, or several read as one (TREE), the
    first that has it; else where the first would have it."""
    dirs = (src,) if isinstance(src, str) else tuple(src)
    for d in dirs:
        path = os.path.join(d, name)
        if os.path.isfile(path):
            return path
    return os.path.join(dirs[0], name)


def listing(src):
    """Every file name in `src`: a folder, or several read as one."""
    dirs = (src,) if isinstance(src, str) else tuple(src)
    return sorted({n for d in dirs for n in os.listdir(d)})


def listing_all(src):
    """Every file in `src` and the folders under it, by its path from the
    folder (`script/lex.zig`): a folder, or several read as one."""
    dirs = (src,) if isinstance(src, str) else tuple(src)
    return sorted({os.path.relpath(os.path.join(folder, n), d)
                   for d in dirs for folder, _, names in os.walk(d) for n in names})

_IMPORT = re.compile(r'@import\(\s*"([^"]+\.zig)"\s*,?\s*\)')
_MODULE = re.compile(r'@import\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,?\s*\)')
_EMBED = re.compile(r'@embedFile\(\s*"([^"]+)"\s*,?\s*\)')


def _scan(line):
    """(end of code, [(start, end) of each literal's contents])."""
    stripped = line.lstrip()
    if stripped.startswith("\\\\"):
        start = len(line) - len(stripped)
        return len(line.rstrip("\n")), [(start + 2, len(line.rstrip("\n")))]
    spans, i, n = [], 0, len(line)
    while i < n:
        ch = line[i]
        if ch == "/" and line.startswith("//", i):
            return i, spans
        if ch in "\"'":
            j = i + 1
            while j < n and line[j] != ch:
                j += 2 if line[j] == "\\" else 1
            spans.append((i + 1, min(j, n)))
            i = j + 1
            continue
        i += 1
    return len(line.rstrip("\n")), spans


def code(line):
    end, _ = _scan(line)
    return line[:end]


def blank(line):
    end, spans = _scan(line)
    chars = list(line[:end])
    for a, b in spans:
        for k in range(a, min(b, end)):
            chars[k] = " "
    return "".join(chars)


def _code_text(text):
    return "\n".join(code(line) for line in text.splitlines())


def imports(text):
    return _IMPORT.findall(_code_text(text))


def modules(text):
    return _MODULE.findall(_code_text(text))


def embeds(text):
    return _EMBED.findall(_code_text(text))


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
        for ch in blank(line):
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
        for ch in blank(line):
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


def _self_test():
    assert code('const u = "http://x"; // a comment\n') == 'const u = "http://x"; '
    assert code("const c = '/'; // x") == "const c = '/'; "
    assert code('    \\\\// all literal\n') == '    \\\\// all literal'
    assert blank("if (c == '{') {") == "if (c == ' ') {"
    assert blank('x("}") }') == 'x(" ") }'
    assert imports('const a = @import(\n    "users.zig",\n);\n') == ["users.zig"]
    assert imports('// const a = @import("users.zig");\n') == []
    assert imports('const s = "@import(\\"x.zig\\")";\n') == []
    assert embeds('const j = @embedFile("chat.js");\n') == ["chat.js"]
    def lines(text):
        return text.splitlines(keepends=True)
    block = lines('const ok = 1;\ntest "x" {\n    const s = "}";\n    if (c == \'{\') {}\n    if (true) {\n        for (xs) |x| { _ = x; }\n    }\n}\nconst b = 2;\n')
    assert test_lines(block) == {2, 3, 4, 5, 6, 7, 8}
    assert test_lines(lines('test "esc" {\n    const s = "a \\" } b";\n}\nconst c = 1;\n')) == {1, 2, 3}
    assert test_lines(lines('fn testHelper() void {}\nconst x = base +\n    testValue;\n')) == set()
    helpers = lines('fn lower() void {}\nconst Fixture = struct {\n    fn seed() void { lower(); }\n};\nfn shared() void {}\npub fn serve() void { shared(); }\npub fn open() void {}\nfn unused() void {}\ntest "x" {\n    Fixture.seed();\n    shared();\n    open();\n}\n')
    tests = test_lines(helpers)
    assert tests == {9, 10, 11, 12, 13}
    assert test_only_lines(helpers, tests) == {1, 2, 3, 4}  # not shared (code uses it), open (pub), unused
    assert modules('const std = @import("std");\nconst w = @import(\n    "webbox",\n).http;\nconst u = @import("users.zig");\n') == ["std", "webbox"]


if __name__ == "__main__":
    _self_test()
    print("zig_source: its self-test passes")
