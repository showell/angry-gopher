const std = @import("std");

/// render turns a raw chat message body into HTML, matching the Go
/// RenderChatMarkdown oracle (goldmark GFM + hard-wraps, then escape-but-img
/// and the MSG_ linkifier) byte-for-byte. Built up feature by feature against
/// the gold corpus. Currently: plain-text paragraphs (hard wraps + escaping)
/// plus the MSG_ reference linkifier.
///
/// Caller owns the returned slice; pass an arena and reset it per message.
pub fn render(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    const body = try renderBlocks(a, md);
    return try linkifyMsgRefs(a, body);
}

// --- block rendering --------------------------------------------------------

fn renderBlocks(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |ln| try lines.append(a, ln);
    const arr = lines.items;

    var idx: usize = 0;
    while (idx < arr.len) {
        if (isBlank(arr[idx])) {
            idx += 1;
            continue;
        }
        // A paragraph is a maximal run of non-blank lines.
        const start = idx;
        while (idx < arr.len and !isBlank(arr[idx])) : (idx += 1) {}

        try out.appendSlice(a, "<p>");
        var k = start;
        while (k < idx) : (k += 1) {
            try escapeInto(&out, a, trimLine(arr[k]));
            if (k + 1 < idx) try out.appendSlice(a, "<br>\n"); // hard wrap
        }
        try out.appendSlice(a, "</p>\n");
    }

    return out.toOwnedSlice(a);
}

fn isBlank(line: []const u8) bool {
    return trimLine(line).len == 0;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn escapeInto(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
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

// --- MSG_ reference linkifier (post-pass over rendered HTML) -----------------

/// linkifyMsgRefs rewrites MSG_<slug>_<n> tokens in HTML text into reference
/// links, skipping the contents of <code>, <pre>, and <a> elements — the same
/// single tokenizing walk (tags vs. text) as the Go linkifyMsgRefs.
fn linkifyMsgRefs(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var skip: usize = 0; // depth inside code/pre/a, where we don't rewrite
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse {
                try out.appendSlice(a, html[i..]);
                break;
            };
            const tag = html[i .. end + 1];
            try out.appendSlice(a, tag);
            if (tagOpensSkip(tag)) {
                skip += 1;
            } else if (tagClosesSkip(tag) and skip > 0) {
                skip -= 1;
            }
            i = end + 1;
            continue;
        }
        const next = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
        const text = html[i..next];
        if (skip == 0) {
            try linkifyText(&out, a, text);
        } else {
            try out.appendSlice(a, text);
        }
        i = next;
    }
    return out.toOwnedSlice(a);
}

fn tagOpensSkip(tag: []const u8) bool {
    return startsWithCI(tag, "<code") or startsWithCI(tag, "<pre") or startsWithCI(tag, "<a ");
}

fn tagClosesSkip(tag: []const u8) bool {
    return startsWithCI(tag, "</code") or startsWithCI(tag, "</pre") or startsWithCI(tag, "</a");
}

fn linkifyText(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (msgRefEnd(text, i)) |end| {
            const slug = text[i + 4 .. end]; // group: <slug>_<n>
            try out.appendSlice(a, "<a href=\"#msg-");
            try out.appendSlice(a, slug);
            try out.appendSlice(a, "\" class=\"msg-ref\">MSG_");
            try out.appendSlice(a, slug);
            try out.appendSlice(a, "</a>");
            i = end;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
}

/// msgRefEnd matches \bMSG_([A-Za-z0-9-]+_[0-9]+)\b starting at text[i],
/// returning the index just past the match, or null. Mirrors msgRefRe.
fn msgRefEnd(text: []const u8, i: usize) ?usize {
    if (i + 4 > text.len or !std.mem.eql(u8, text[i .. i + 4], "MSG_")) return null;
    if (i > 0 and isWordChar(text[i - 1])) return null; // \b before
    var j = i + 4;
    const slug_start = j;
    while (j < text.len and isSlugChar(text[j])) : (j += 1) {}
    if (j == slug_start) return null; // need >=1 slug char
    if (j >= text.len or text[j] != '_') return null;
    j += 1;
    const dig_start = j;
    while (j < text.len and isDigit(text[j])) : (j += 1) {}
    if (j == dig_start) return null; // need >=1 digit
    if (j < text.len and isWordChar(text[j])) return null; // \b after
    return j;
}

// --- small char/string helpers ----------------------------------------------

fn isWordChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '_';
}

fn isSlugChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlnum(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or isDigit(c);
}

fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (prefix, 0..) |p, n| {
        if (lower(haystack[n]) != lower(p)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
