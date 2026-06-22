//! markdown_fence.zig: the chat dialect's fenced-code grammar as line-based predicates.
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

/// max_nest_levels caps how deeply quote-replies (or fenced code) may nest.
/// Genuine nesting REQUIRES growing the fence (CommonMark closes on the first
/// fence of >= length, so an inner fence must be shorter than its outer) — the
/// quote-reply UI grows it by one char per level, starting at 3 for level 1. So
/// level N is an (N+2)-char run, and the cap is a max opener length: a longer
/// run isn't treated as a fence at all (its chars render as ordinary text),
/// which bounds a pathological deep nest instead of parsing into it. 8 levels is
/// already well past sane (5 would be borderline insane); 9-deep degrades.
pub const max_nest_levels = 8;
const max_run = max_nest_levels + 2; // a level-8 opener is 10 chars

/// Open describes a recognized fence opener. A valid close needs `>= count` of
/// the same `char` — so a longer outer fence safely contains a shorter inner one.
pub const Open = struct {
    char: u8, // '`' or '~'
    count: usize, // length of the opening run (3..max_run)
    indent: usize, // leading spaces (0..3), needed to de-indent the body
    lang: []const u8, // first whitespace-delimited token of the info string
};

/// parseOpen recognizes a fence opener on one line: up to 3 leading spaces, then
/// 3..max_run of '`' or '~'. `lang` is the first token of the info string. A
/// backtick info string may not contain a backtick (CommonMark) → not an opener.
/// A run longer than max_run is over the nesting cap → not a fence.
pub fn parseOpen(line: []const u8) ?Open {
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) indent += 1;
    if (indent >= 4 or i >= line.len) return null;
    const f = line[i];
    if (f != '`' and f != '~') return null;
    var count: usize = 0;
    while (i < line.len and line[i] == f) : (i += 1) count += 1;
    if (count < 3 or count > max_run) return null;
    const info = std.mem.trim(u8, line[i..], " \t\r");
    if (f == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    var lang = info;
    if (std.mem.indexOfAny(u8, info, " \t")) |sp| lang = info[0..sp];
    return .{ .char = f, .count = count, .indent = indent, .lang = lang };
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

test "parseOpen caps the nesting depth" {
    // A level-8 opener (max_run chars) is still a fence...
    const ok = "~" ** max_run;
    try testing.expect(parseOpen(ok) != null);
    try testing.expectEqual(@as(usize, max_run), parseOpen(ok).?.count);
    // ...but one char deeper is treated as ordinary text, not a fence.
    const over = "~" ** (max_run + 1);
    try testing.expect(parseOpen(over) == null);
    try testing.expect(parseOpen("`" ** (max_run + 5)) == null);
}

test "isClose is length-aware: a shorter run can't close a longer fence" {
    try testing.expect(!isClose("~~~", '~', 4)); // the bug: 3 must NOT close 4
    try testing.expect(isClose("~~~~", '~', 4));
    try testing.expect(isClose("~~~~~", '~', 4)); // longer is fine
    try testing.expect(!isClose("```", '~', 3)); // wrong char
    try testing.expect(!isClose("~~~ quote", '~', 3)); // info text is never a close
}
