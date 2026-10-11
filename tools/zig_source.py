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
  embeds(text)  every `@embedFile("...")` likewise.

What it does not see: an import through a name (`const s = @import("std");
s.heap...`). The lints that care say so; the build of the port is the guard
there.
"""
import re

_IMPORT = re.compile(r'@import\(\s*"([^"]+\.zig)"\s*,?\s*\)')
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


if __name__ == "__main__":
    _self_test()
    print("zig_source: its self-test passes")
