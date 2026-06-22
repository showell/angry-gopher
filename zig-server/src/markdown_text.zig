//! markdown_text: the shared text primitives of the markdown subsystem — HTML
//! escaping plus the small character-class predicates. A pure leaf (imports
//! nothing but std), so every other markdown module can depend on it without a
//! cycle. Nothing here knows anything about blocks, inlines, or the dialect; it's
//! just "escape this text" and "what kind of byte is this".

const std = @import("std");

/// escapeInto appends `text` to `out` with the five HTML-significant bytes
/// turned into entities (& < > "), so caller-supplied text can never break out
/// of the surrounding markup. THE escaping primitive — every rendered string of
/// untrusted text passes through here.
pub fn escapeInto(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, ch),
        }
    }
}

pub fn isWordChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '_';
}

pub fn isSlugChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-';
}

pub fn isAttrNameChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-' or c == '_' or c == ':';
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isAsciiAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

pub fn isAsciiAlnum(c: u8) bool {
    return isAsciiAlpha(c) or isDigit(c);
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

/// isPunct reports whether c is an ASCII punctuation char (CommonMark's
/// definition), used by the emphasis flanking rules.
pub fn isPunct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

pub fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

pub fn eqlCI(s: []const u8, lower_lit: []const u8) bool {
    if (s.len != lower_lit.len) return false;
    for (s, lower_lit) |c, l| {
        if (lower(c) != l) return false;
    }
    return true;
}

pub fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (prefix, 0..) |p, n| {
        if (lower(haystack[n]) != lower(p)) return false;
    }
    return true;
}

pub fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
