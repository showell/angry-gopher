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

# The tree the lints judge: the application's sources and the library's,
# zig-webbox, a sibling checkout (zig-server/build.zig.zon's dependency). The
# two hold no file of the same name, so a lint reads them as one folder.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_SRC = os.path.join(_REPO, "zig-server", "src")
LIBRARY_SRC = os.path.normpath(os.path.join(_REPO, "..", "zig-webbox", "src"))
TREE = (APP_SRC, LIBRARY_SRC)


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
    assert modules('const std = @import("std");\nconst w = @import(\n    "webbox",\n).http;\nconst u = @import("users.zig");\n') == ["std", "webbox"]


if __name__ == "__main__":
    _self_test()
    print("zig_source: its self-test passes")
