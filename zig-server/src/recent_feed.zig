//! recent_feed: the Recent activity-feed event shape + excerpt rendering, in a
//! leaf module so BOTH consumers share one encoder with no import cycle:
//!   - recent.zig  — renders the initial backlog (one event per gathered item)
//!   - chat_store.zig (appendMessage fanout) — publishes ONE live event per write
//! The recentEvent JSON field order is kind, at, url, who, where, topic,
//! excerpt, slug, title — empties omitted, so recent.js's `if(evt.where)` /
//! `if(evt.excerpt)` branches stay correct. `who` is the author's display name,
//! already rendered "You" for the recipient (the feed is per-viewer).

const std = @import("std");
const Alloc = std.mem.Allocator;
const fence = @import("markdown_fence.zig");

/// recentExcerptCap bounds an excerpt's length on the wire (in codepoints).
pub const recent_excerpt_cap = 350;

/// encodeChatEvent writes one chat recentEvent object into `j`. `dm` flags a
/// 1:1 conversation (vs a channel) so the client can label an incoming DM as
/// "(DM)" rather than the misleading "message to <me>"; emitted only when true.
pub fn encodeChatEvent(j: *std.ArrayList(u8), alloc: Alloc, at: []const u8, url: []const u8, who: []const u8, where: []const u8, topic: []const u8, excerpt: []const u8, dm: bool) !void {
    try j.print(alloc, "{{\"kind\":\"chat\",\"at\":{f}", .{std.json.fmt(at, .{})});
    try appendField(j, alloc, "url", url);
    try appendField(j, alloc, "who", who);
    try appendField(j, alloc, "where", where);
    try appendField(j, alloc, "topic", topic);
    try appendField(j, alloc, "excerpt", excerpt);
    if (dm) try j.appendSlice(alloc, ",\"dm\":true");
    try j.append(alloc, '}');
}

/// encodeDocEvent writes one doc recentEvent object into `j`. `who` is the
/// editor, already "You" for the viewer (docs are the viewer's own).
pub fn encodeDocEvent(j: *std.ArrayList(u8), alloc: Alloc, at: []const u8, who: []const u8, slug: []const u8, title: []const u8) !void {
    try j.print(alloc, "{{\"kind\":\"doc\",\"at\":{f}", .{std.json.fmt(at, .{})});
    try appendField(j, alloc, "who", who);
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
/// markdown: each `quote` fence (a quote-reply) collapses to "[quoted text]" so
/// the message's NEW content survives the cap, image tags (HTML `<img …>` or
/// markdown `![…](…)`) collapse to "[image]", whitespace runs become a single
/// space, trimmed, capped at recent_excerpt_cap codepoints (+ "…"). The client
/// CSS-clamps to three lines.
pub fn recentExcerpt(alloc: Alloc, markdown: []const u8) ![]const u8 {
    const no_quote = try collapseQuotes(alloc, markdown);
    const no_html = try replaceImgHtml(alloc, no_quote);
    const no_md = try replaceImgMarkdown(alloc, no_html);
    const collapsed = try collapseWhitespace(alloc, no_md);
    return capCodepoints(alloc, collapsed, recent_excerpt_cap);
}

/// collapseQuotes replaces each top-level `quote` fence (the quote-reply marker)
/// with the literal "[quoted text]", so a reply's new content isn't crowded out
/// of the excerpt by the quoted body. Fence spans are length-aware (fence.zig),
/// so a quote-of-a-quote — wrapped by the JS in a LONGER outer fence — collapses
/// as one unit (the inner quote is inside it). Runs before whitespace collapse,
/// while line structure is still intact. The "In MSG_… said:" preamble line is
/// left as-is (it carries the relative attribution).
fn collapseQuotes(alloc: Alloc, markdown: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var lit = std.mem.splitScalar(u8, markdown, '\n');
    while (lit.next()) |ln| try lines.append(alloc, ln);
    const ls = lines.items;

    var i: usize = 0;
    while (i < ls.len) {
        if (fence.parseOpen(ls[i])) |fo| {
            // Consume the whole fence span (length-aware close, or EOF).
            var j = i + 1;
            while (j < ls.len and !fence.isClose(ls[j], fo.char, fo.count)) : (j += 1) {}
            if (std.mem.eql(u8, fo.lang, "quote")) {
                try out.appendSlice(alloc, "[quoted text]\n");
            } else {
                // A real code block — keep it verbatim so its interior lines
                // aren't re-read as quote openers.
                for (ls[i .. @min(j + 1, ls.len)]) |code_line| {
                    try out.appendSlice(alloc, code_line);
                    try out.append(alloc, '\n');
                }
            }
            i = j + 1;
            continue;
        }
        try out.appendSlice(alloc, ls[i]);
        try out.append(alloc, '\n');
        i += 1;
    }
    return out.toOwnedSlice(alloc);
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

test "recentExcerpt collapses a nested quote and keeps the new content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\In MSG_test_2 I said:
        \\~~~~ quote
        \\In MSG_test_1 I said:
        \\~~~ quote
        \\hi
        \\~~~
        \\
        \\hello
        \\~~~~
        \\
        \\yo
    ;
    const ex = try recentExcerpt(arena.allocator(), body);
    try std.testing.expectEqualStrings("In MSG_test_2 I said: [quoted text] yo", ex);
}

test "recentExcerpt leaves a real code block intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ex = try recentExcerpt(arena.allocator(), "look:\n```\ncode here\n```\ndone");
    try std.testing.expectEqualStrings("look: ``` code here ``` done", ex);
}

test "encodeChatEvent: dm:true is emitted for a 1:1 conv, omitted for a channel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    defer arena.deinit();

    var dm: std.ArrayList(u8) = .empty;
    try encodeChatEvent(&dm, a, "2026-06-24T00:00:00Z", "/chat/c/1_3/yo", "Claude", "to Claude", "yo", "", true);
    try std.testing.expect(std.mem.indexOf(u8, dm.items, "\"dm\":true") != null);

    var ch: std.ArrayList(u8) = .empty;
    try encodeChatEvent(&ch, a, "2026-06-24T00:00:00Z", "/channel/general/yo", "Claude", "in general", "yo", "", false);
    try std.testing.expect(std.mem.indexOf(u8, ch.items, "\"dm\"") == null);
}
