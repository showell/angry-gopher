//! recent_feed: the Recent activity-feed event shape + excerpt rendering, in a
//! leaf module so BOTH consumers share one encoder with no import cycle:
//!   - recent.zig  — renders the initial backlog (one event per gathered item)
//!   - chat_store.zig (appendMessage fanout) — publishes ONE live event per write
//! The recentEvent JSON field order is kind, at, url, topic, where, last_author,
//! excerpt, slug, title — empties omitted, so recent.js's `if(evt.last_author)` /
//! `if(evt.where)` / `if(evt.excerpt)` branches stay correct.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// recentExcerptCap bounds an excerpt's length on the wire (in codepoints).
pub const recent_excerpt_cap = 280;

/// encodeChatEvent writes one chat recentEvent object into `j`.
pub fn encodeChatEvent(j: *std.ArrayList(u8), alloc: Alloc, at: []const u8, url: []const u8, topic: []const u8, where: []const u8, last_author: []const u8, excerpt: []const u8) !void {
    try j.print(alloc, "{{\"kind\":\"chat\",\"at\":{f}", .{std.json.fmt(at, .{})});
    try appendField(j, alloc, "url", url);
    try appendField(j, alloc, "topic", topic);
    try appendField(j, alloc, "where", where);
    try appendField(j, alloc, "last_author", last_author);
    try appendField(j, alloc, "excerpt", excerpt);
    try j.append(alloc, '}');
}

/// encodeDocEvent writes one doc recentEvent object into `j`.
pub fn encodeDocEvent(j: *std.ArrayList(u8), alloc: Alloc, at: []const u8, slug: []const u8, title: []const u8) !void {
    try j.print(alloc, "{{\"kind\":\"doc\",\"at\":{f}", .{std.json.fmt(at, .{})});
    try appendField(j, alloc, "slug", slug);
    try appendField(j, alloc, "title", title);
    try j.append(alloc, '}');
}

fn appendField(j: *std.ArrayList(u8), alloc: Alloc, name: []const u8, val: []const u8) !void {
    if (val.len == 0) return; // omitempty
    try j.print(alloc, ",\"{s}\":{f}", .{ name, std.json.fmt(val, .{}) });
}

// ── recentExcerpt ──────────────

/// recentExcerpt renders a one-line plain-text preview of a message's raw
/// markdown: image tags (HTML `<img …>` or markdown `![…](…)`) collapse to
/// "[image]", whitespace runs become a single space, trimmed, capped at
/// recent_excerpt_cap codepoints (+ "…"). The client CSS-clamps to three lines.
pub fn recentExcerpt(alloc: Alloc, markdown: []const u8) ![]const u8 {
    const no_html = try replaceImgHtml(alloc, markdown);
    const no_md = try replaceImgMarkdown(alloc, no_html);
    const collapsed = try collapseWhitespace(alloc, no_md);
    return capCodepoints(alloc, collapsed, recent_excerpt_cap);
}

/// replaceImgHtml collapses each `<img\b[^>]*>` span to "[image]" (case-
/// insensitive, spans newlines). The `\b` after "img" rejects "<imgx…".
fn replaceImgHtml(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 4 <= s.len and std.ascii.eqlIgnoreCase(s[i .. i + 4], "<img") and
            (i + 4 == s.len or !isWordByte(s[i + 4])))
        {
            if (std.mem.indexOfScalarPos(u8, s, i + 4, '>')) |gt| {
                try out.appendSlice(alloc, "[image]");
                i = gt + 1;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// replaceImgMarkdown collapses each `!\[[^\]]*\]\([^)]*\)` to "[image]".
fn replaceImgMarkdown(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (matchMdImage(s, i)) |end| {
                try out.appendSlice(alloc, "[image]");
                i = end;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// matchMdImage returns the index just past a `![alt](url)` starting at `start`
/// (which points at '!'), or null. `alt` is `[^\]]*`, `url` is `[^)]*`.
fn matchMdImage(s: []const u8, start: usize) ?usize {
    var i = start + 2; // past "!["
    const alt_end = std.mem.indexOfScalarPos(u8, s, i, ']') orelse return null;
    i = alt_end + 1;
    if (i >= s.len or s[i] != '(') return null;
    i += 1;
    const url_end = std.mem.indexOfScalarPos(u8, s, i, ')') orelse return null;
    return url_end + 1;
}

/// collapseWhitespace replaces every run of `\s` with a single space, then trims.
fn collapseWhitespace(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (s) |c| {
        if (isSpace(c)) {
            in_ws = true;
        } else {
            if (in_ws and out.items.len > 0) try out.append(alloc, ' ');
            in_ws = false;
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// capCodepoints truncates to `cap` Unicode codepoints, appending "…" (and
/// trimming a trailing space) when it had to cut.
fn capCodepoints(alloc: Alloc, s: []const u8, cap: usize) ![]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (count == cap) {
            const head = std.mem.trimEnd(u8, s[0..i], " ");
            return std.fmt.allocPrint(alloc, "{s}…", .{head});
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += len;
        count += 1;
    }
    return s;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

fn isWordByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}
