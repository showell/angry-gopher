//! fence.zig: the chat dialect's fenced-code grammar as line-based predicates.
//!
//! markdown.zig (the renderer, the dialect's source of truth) parses fences
//! offset-into-the-document via parseFenceOpen/isClosingFence. This module is
//! the SAME CommonMark grammar expressed over already-split lines, for the two
//! consumers that walk a message line by line: code_store.extractCodeBlocks
//! (the Code view) and recent_feed.recentExcerpt (quote collapsing). Keep it in
//! agreement with markdown.zig — a past divergence (a consumer assuming a fence
//! is exactly three chars) is the bug this module exists to retire: a `~~~~`
//! quote-of-a-quote was misread as code because its opener wasn't length-aware.

const std = @import("std");

/// Open describes a recognized fence opener. A valid close needs `>= count` of
/// the same `char` — so a longer outer fence safely contains a shorter inner one.
pub const Open = struct {
    char: u8, // '`' or '~'
    count: usize, // length of the opening run
    lang: []const u8, // first whitespace-delimited token of the info string
};

/// parseOpen recognizes a fence opener on one line: up to 3 leading spaces, then
/// >= 3 of '`' or '~'. `lang` is the first token of the info string. A backtick
/// info string may not contain a backtick (CommonMark) → not an opener.
pub fn parseOpen(line: []const u8) ?Open {
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) indent += 1;
    if (indent >= 4 or i >= line.len) return null;
    const f = line[i];
    if (f != '`' and f != '~') return null;
    var count: usize = 0;
    while (i < line.len and line[i] == f) : (i += 1) count += 1;
    if (count < 3) return null;
    const info = std.mem.trim(u8, line[i..], " \t\r");
    if (f == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    var lang = info;
    if (std.mem.indexOfAny(u8, info, " \t")) |sp| lang = info[0..sp];
    return .{ .char = f, .count = count, .lang = lang };
}

/// isClose reports whether `line` closes a fence opened with `char` × `count`:
/// up to 3 leading spaces, then >= count of `char`, then only whitespace (no
/// info text — per CommonMark a closing fence carries none).
pub fn isClose(line: []const u8, char: u8, count: usize) bool {
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) indent += 1;
    if (indent >= 4) return false;
    var n: usize = 0;
    while (i < line.len and line[i] == char) : (i += 1) n += 1;
    if (n < count) return false;
    return std.mem.trim(u8, line[i..], " \t\r").len == 0;
}

const testing = std.testing;

test "parseOpen reads the full marker run, not just three" {
    const q = parseOpen("~~~~ quote").?;
    try testing.expectEqual(@as(u8, '~'), q.char);
    try testing.expectEqual(@as(usize, 4), q.count);
    try testing.expectEqualStrings("quote", q.lang);

    const z = parseOpen("```zig").?;
    try testing.expectEqual(@as(u8, '`'), z.char);
    try testing.expectEqual(@as(usize, 3), z.count);
    try testing.expectEqualStrings("zig", z.lang);

    try testing.expect(parseOpen("plain text") == null);
    try testing.expect(parseOpen("~~ short") == null);
    try testing.expect(parseOpen("```a`b") == null); // backtick in backtick info
}

test "isClose is length-aware: a shorter run can't close a longer fence" {
    try testing.expect(!isClose("~~~", '~', 4)); // the bug: 3 must NOT close 4
    try testing.expect(isClose("~~~~", '~', 4));
    try testing.expect(isClose("~~~~~", '~', 4)); // longer is fine
    try testing.expect(!isClose("```", '~', 3)); // wrong char
    try testing.expect(!isClose("~~~ quote", '~', 3)); // info text is never a close
}
