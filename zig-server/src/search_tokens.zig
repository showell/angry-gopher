//! search_tokens: the words of a chat message, as search knows them
//! (metal-vmm QUEUE 155(a)). **THE SERVER'S ALONE**: the client asks the
//! server for words and messages and renders them; it never tokenizes.
//!
//! - **Words split on ASCII whitespace** only: a no-break or zero-width
//!   space inside a run glues the words either side into one (a no-break
//!   space at a word's edge is trimmed, below).
//! - **Edge punctuation trimmed**, from both ends, again and again: ASCII
//!   punctuation, and the curly quotes and apostrophes phones type, with
//!   others like them, all in `trimmed` (Steve: trim curlies and similar).
//!   What is inside a word stays: "don't", "e.g", "3.14".
//! - **ASCII lowercased** (`fold`); any byte >= 0x80 is a word character, so
//!   a word in another script is matched byte for byte.
//! - **Two bytes or more**: a word shorter than that after trimming is no
//!   word (one letter would match nearly everything, as /admin/search's
//!   `min_key` says).
//!
//! URLs, phone numbers and markdown links are refined later, not now: today
//! "[text](https://x.y/z)" is one word, trimmed at its ends.
//!
//! Pure: no I/O, no allocation but the caller's.

const std = @import("std");

/// The shortest word, in bytes.
pub const min_len = 2;
/// **THE LONGEST WORD A KEY CAN NAME**, in bytes: the routes read a key of at
/// most this, and suggest no longer word (a URL is one word today), so a word
/// suggested is always one a search finds (the box's review of 155).
pub const max_word = 256;

/// **WHAT IS TRIMMED FROM A WORD'S ENDS BESIDES ASCII PUNCTUATION**, as
/// UTF-8: quotes and apostrophes of every kind a keyboard or a phone types,
/// the guillemets, the ellipsis and the dashes, the inverted marks, the
/// primes, and the no-break space.
pub const trimmed = [_][]const u8{
    "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", // ‘ ’ ‚ ‛
    "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", // “ ” „ ‟
    "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}", // « » ‹ ›
    "\u{2026}", "\u{2013}", "\u{2014}", "\u{2015}", // … – — ―
    "\u{00A1}", "\u{00BF}", "\u{2032}", "\u{2033}", // ¡ ¿ ′ ″
    "\u{00A0}", // no-break space
};

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// `word` with its edge punctuation trimmed, from both ends until neither
/// end is any.
pub fn trim(word: []const u8) []const u8 {
    var w = word;
    outer: while (w.len > 0) {
        if (isAsciiPunct(w[0])) {
            w = w[1..];
            continue;
        }
        if (isAsciiPunct(w[w.len - 1])) {
            w = w[0 .. w.len - 1];
            continue;
        }
        for (trimmed) |t| {
            if (std.mem.startsWith(u8, w, t)) {
                w = w[t.len..];
                continue :outer;
            }
            if (std.mem.endsWith(u8, w, t)) {
                w = w[0 .. w.len - t.len];
                continue :outer;
            }
        }
        break;
    }
    return w;
}

/// The words of `text`, in order, each trimmed but not folded: slices of
/// `text` (`fold` lowercases one).
pub const Words = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        while (self.at < self.text.len) {
            while (self.at < self.text.len and std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
            const start = self.at;
            while (self.at < self.text.len and !std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
            const w = trim(self.text[start..self.at]);
            if (w.len >= min_len) return w;
        }
        return null;
    }
};

pub fn words(text: []const u8) Words {
    return .{ .text = text };
}

/// `word` with its ASCII letters lowercased, into `out` (as long as it).
pub fn fold(word: []const u8, out: []u8) []u8 {
    for (word, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out[0..word.len];
}

/// A key as typed (a word, or the start of one) as the index holds words:
/// trimmed and folded, into `out`. Empty when nothing of it is a word's.
pub fn key(typed: []const u8, out: []u8) []u8 {
    const t = trim(std.mem.trim(u8, typed, " \t\r\n"));
    if (t.len > out.len) return out[0..0];
    return fold(t, out);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectWords(text: []const u8, want: []const []const u8) !void {
    var it = words(text);
    var buf: [256]u8 = undefined;
    for (want) |w| {
        const got = it.next() orelse return error.TooFewWords;
        try testing.expectEqualStrings(w, fold(got, &buf));
    }
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "words split on whitespace, ASCII lowercased" {
    try expectWords("The page  LAYOUT\tis\noff", &.{ "the", "page", "layout", "is", "off" });
    try expectWords("", &.{});
    try expectWords(" \t\n ", &.{});
}

test "edge punctuation is trimmed, from both ends and again; what is inside stays" {
    try expectWords("Hello, world!", &.{ "hello", "world" });
    try expectWords("(\"quoted\"), [x1] {braces}...", &.{ "quoted", "x1", "braces" });
    try expectWords("don't e.g. 3.14 a-b", &.{ "don't", "e.g", "3.14", "a-b" });
    try expectWords("--dashes-- **bold** _em_ `code`", &.{ "dashes", "bold", "em", "code" });
}

test "the curly quotes and apostrophes a phone types are trimmed, and their kin" {
    try expectWords("\u{201C}Hello\u{201D} \u{2018}there\u{2019}", &.{ "hello", "there" });
    try expectWords("\u{00AB}Bonjour\u{00BB} \u{2039}x1\u{203A} wait\u{2026} \u{00BF}Qu\u{00E9}?", &.{ "bonjour", "x1", "wait", "qu\u{00E9}" });
    // Inside a word, a curly apostrophe stays: "don’t" is a word of its own.
    try expectWords("don\u{2019}t", &.{"don\u{2019}t"});
    // Mixed, layered: “(‘word’)”.
    try expectWords("\u{201C}(\u{2018}word\u{2019})\u{201D}", &.{"word"});
}

test "a byte >= 0x80 is a word character, matched exactly; only ASCII folds" {
    try expectWords("Caf\u{00E9} \u{00C9}t\u{00E9} \u{65E5}\u{672C}", &.{ "caf\u{00E9}", "\u{00C9}t\u{00E9}", "\u{65E5}\u{672C}" });
    // An emoji alone is a word: four bytes.
    try expectWords("ok \u{1F600}", &.{ "ok", "\u{1F600}" });
}

test "a word is two bytes or more" {
    try expectWords("a I x. ab (c) \u{00E9}", &.{ "ab", "\u{00E9}" });
    try expectWords("!!! ... \u{201C}\u{201D}", &.{});
}

test "a key as typed is a word's start, trimmed and folded like one" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("lay", key("  Lay ", &buf));
    try testing.expectEqualStrings("don't", key("\u{201C}Don't", &buf));
    try testing.expectEqualStrings("", key("?!", &buf));
    var small: [2]u8 = undefined;
    try testing.expectEqualStrings("", key("long", &small));
}
