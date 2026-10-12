//! chat_search: search across every conversation a person can see, the
//! server side (metal-vmm QUEUE 155(d)). Two routes, JSON, members only (the
//! /chat gate):
//!
//!   GET /chat/search/words?prefix=la    the words beginning so, each with
//!       how many messages hold it, summed over what the viewer can see; at
//!       most `most_words` (said as "most"), the most held first:
//!       {"prefix":"la","most":20,"unreadable":0,"words":[{"word":"layout","count":3},...]}
//!   GET /chat/search/messages?word=layout   the messages holding the word:
//!       {"word":"layout","matched":N,"unreadable":0,"messages":[{"conv":"/chat/c/1_2",
//!       "kind":"dm","sid":..,"id":..,"from":..,"date":..,"before":..,"mark":..,"after":..},...]}
//!       at most `most_messages` listed, and at most `most_bytes` of their
//!       text as JSON writes it, every one counted. Each message is its
//!       excerpt, cut here (`excerptOf`): the word as the index read it,
//!       marked, and up to `excerpt_pad` bytes either side, "…" where cut
//!       (metal-vmm QUEUE 157(d): the client re-read the word's edges with a
//!       regex of its own, and they had already come apart on Unicode spaces).
//!
//! **WHAT THE VIEWER CAN SEE, ASKED ON EVERY REQUEST** (`chat_store.
//! visibleConvs`), never a list kept from an earlier one: a DM between two
//! others, or a channel the viewer is not in, is neither suggested nor found.
//!
//! **A CRUDE RATE LIMIT** (Steve): `per_second` searches a second per
//! person, both routes together, which debounced typing never meets; past
//! it, 429.
//!
//! `unreadable` counts the transcripts of the viewer's conversations the
//! index could not read: a search there may miss their words.
//!
//! The words are the server's alone (`search_tokens`): the client sends what
//! was typed and renders what comes back. The UI is later (`chat_search.js`
//! is untouched).

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("webbox").http;
const chat = @import("chat.zig");
const chat_store = @import("chat_store.zig");
const search_index = @import("search_index.zig");
const tokens = @import("search_tokens.zig");
const mem_meter = @import("webbox").mem_meter;

const Request = std.http.Server.Request;

pub const most_words = 20;
/// Bytes of a message either side of the marked word in its excerpt.
pub const excerpt_pad = 90;
pub const most_messages = 500;
pub const per_second = 5;
/// The most bytes of message text one answer lists, as JSON writes it
/// (`search_index.jsonCost`; a doc posted to chat is one message of up to
/// 1 MiB): past it the listing stops, every match still counted (the box's
/// review of 155, and the review of its fix).
pub const most_bytes = 2 << 20;

/// `rest` is the path after "/chat/search".
pub fn handle(req: *Request, io: Io, alloc: Alloc, uid: []const u8, rest: []const u8) !void {
    const words_route = std.mem.eql(u8, rest, "/words");
    if (!words_route and !std.mem.eql(u8, rest, "/messages")) return http.notFound(req);
    if (req.head.method != .GET) return http.methodNotAllowed(req);
    if (!admit(uid, nowMs(io))) {
        return req.respond("{\"error\":\"too many searches; wait a second\"}", .{ .status = .too_many_requests, .extra_headers = &.{http.json_ct} });
    }
    const raw = http.queryValue(try http.target(req, alloc), if (words_route) "prefix" else "word") orelse "";
    var buf: [tokens.max_word]u8 = undefined;
    const key = tokens.key(try chat.urlDecode(alloc, raw), &buf);
    const reach = try chat_store.visibleConvs(io, alloc, uid);
    const idx = search_index.ready(io, alloc) orelse {
        return req.respond("{\"error\":\"search is not ready\"}", .{ .status = .service_unavailable, .extra_headers = &.{http.json_ct} });
    };
    var b: std.ArrayList(u8) = .empty;
    if (words_route) {
        // An empty prefix suggests nothing: every word is not a suggestion.
        const got = if (key.len == 0) &[_]search_index.WordCount{} else try idx.wordsFor(alloc, reach, key, most_words);
        try b.appendSlice(alloc, "{\"prefix\":");
        try str(&b, alloc, key);
        try b.print(alloc, ",\"most\":{d},\"unreadable\":{d},\"words\":[", .{ most_words, idx.unreadableFor(reach) });
        for (got, 0..) |w, i| {
            if (i > 0) try b.append(alloc, ',');
            try b.appendSlice(alloc, "{\"word\":");
            try str(&b, alloc, w.word);
            try b.print(alloc, ",\"count\":{d}}}", .{w.count});
        }
    } else {
        const f = if (key.len < tokens.min_len) search_index.Found{ .hits = &.{}, .matched = 0 } else try idx.messagesFor(alloc, reach, key, most_messages, .{ .bytes = most_bytes, .cost = excerptCost });
        try b.appendSlice(alloc, "{\"word\":");
        try str(&b, alloc, key);
        // **SIZED ONCE**: grown as it is written, the request's arena would
        // keep every smaller copy of the answer besides the last.
        var size: usize = 128;
        for (f.hits) |h| size += 128 + excerptCost(h.msg.markdown, key) + search_index.jsonCost(h.msg.from) +
            search_index.jsonCost(h.msg.sid) + search_index.jsonCost(h.msg.id) + search_index.jsonCost(h.msg.date) + search_index.jsonCost(h.conv.base);
        try b.ensureTotalCapacity(alloc, b.items.len + size);
        try b.print(alloc, ",\"matched\":{d},\"unreadable\":{d},\"messages\":[", .{ f.matched, idx.unreadableFor(reach) });
        for (f.hits, 0..) |h, i| {
            if (i > 0) try b.append(alloc, ',');
            const ex = try excerptOf(alloc, h.msg.markdown, key);
            const fields = [_][2][]const u8{
                .{ "{\"conv\":", h.conv.base },
                .{ ",\"kind\":", @tagName(h.conv.kind) },
                .{ ",\"sid\":", h.msg.sid },
                .{ ",\"id\":", h.msg.id },
                .{ ",\"from\":", h.msg.from },
                .{ ",\"date\":", h.msg.date },
                .{ ",\"before\":", ex.before },
                .{ ",\"mark\":", ex.mark },
                .{ ",\"after\":", ex.after },
            };
            for (fields) |fv| {
                try b.appendSlice(alloc, fv[0]);
                try str(&b, alloc, fv[1]);
            }
            try b.append(alloc, '}');
        }
    }
    try b.appendSlice(alloc, "]}");
    try req.respond(b.items, .{ .extra_headers = &.{http.json_ct} });
}

pub const Excerpt = struct { before: []const u8, mark: []const u8, after: []const u8 };

/// A message's excerpt around `key` (folded): the word as written, where the
/// index finds it (`search_index.wordAt`), and up to `excerpt_pad` bytes
/// either side, cut on a character's edge, "…" where cut. A message the index
/// matched always holds it; one that somehow does not is its first bytes,
/// unmarked.
pub fn excerptOf(alloc: Alloc, md: []const u8, key: []const u8) !Excerpt {
    const at = search_index.wordAt(md, key) orelse {
        const end = charEdgeBack(md, @min(md.len, 2 * excerpt_pad));
        return .{ .before = "", .mark = "", .after = try cut(alloc, "", md[0..end], end < md.len) };
    };
    // Never across the word (the review of 157): a word may begin or end in
    // stray continuation bytes, which the tokenizer counts as a word's, and
    // moving to a character's edge would cross it.
    const start = @min(charEdgeFwd(md, at -| excerpt_pad), at);
    const end = @max(charEdgeBack(md, @min(md.len, at + key.len + excerpt_pad)), at + key.len);
    return .{
        .before = try cut(alloc, if (start > 0) "\u{2026}" else "", md[start..at], false),
        .mark = md[at .. at + key.len],
        .after = try cut(alloc, "", md[at + key.len .. end], end < md.len),
    };
}

/// What a message's excerpt costs as JSON, at most: the window `excerptOf`
/// cuts, and its two marks of a cut. What the route charges its budget.
pub fn excerptCost(md: []const u8, key: []const u8) usize {
    const at = search_index.wordAt(md, key) orelse 0;
    const lo = at -| excerpt_pad;
    const hi = @min(md.len, at + key.len + excerpt_pad);
    return search_index.jsonCost(md[@min(lo, hi)..hi]) + 2 * "\u{2026}".len + 32;
}

fn cut(alloc: Alloc, lead: []const u8, s: []const u8, trailing: bool) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ lead, s, if (trailing) "\u{2026}" else "" });
}

/// `i`, or the next character's start after it: never inside a UTF-8 sequence.
fn charEdgeFwd(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and s[j] & 0xC0 == 0x80) j += 1;
    return j;
}

/// `i`, or the start of the character it falls inside.
fn charEdgeBack(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and j < s.len and s[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

/// `s` as a JSON string. **ALWAYS A STRING** (155's review): std.json writes
/// bytes that are not UTF-8 as an array of numbers, and nothing checks a
/// message's bytes on the way in; each byte that does not begin a whole
/// UTF-8 sequence is written as U+FFFD.
fn str(b: *std.ArrayList(u8), alloc: Alloc, s: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(s)) return b.print(alloc, "{f}", .{std.json.fmt(s, .{})});
    var clean: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
            try clean.appendSlice(alloc, s[i..][0..n]);
            i += n;
        } else {
            try clean.appendSlice(alloc, "\u{FFFD}");
            i += 1;
        }
    }
    return b.print(alloc, "{f}", .{std.json.fmt(clean.items, .{})});
}

// ── the rate limit ───────────────────────────────────────────────────────────

const Window = struct { start_ms: i64, n: u32 };
var windows: std.StringHashMapUnmanaged(Window) = .empty;

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

/// Whether `uid` may search at `now_ms`: at most `per_second` in a second.
/// Its map holds a member each, so it is bounded by the roster. A failure to
/// remember is a search let through: the limit is a courtesy, not a guard.
pub fn admit(uid: []const u8, now_ms: i64) bool {
    const gpa = mem_meter.base();
    const gop = windows.getOrPut(gpa, uid) catch return true;
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, uid) catch {
            windows.removeByPtr(gop.key_ptr);
            return true;
        };
        gop.value_ptr.* = .{ .start_ms = now_ms, .n = 0 };
    }
    const w = gop.value_ptr;
    if (now_ms - w.start_ms >= 1000 or now_ms < w.start_ms) w.* = .{ .start_ms = now_ms, .n = 0 };
    if (w.n >= per_second) return false;
    w.n += 1;
    return true;
}

/// **FOR A TEST: NO WINDOW NOW, AND NONE AFTER** (`defer forgot.end()`; 157(e)).
pub fn forgetForTest() Forgot {
    forgetAll();
    return .{};
}

pub const Forgot = struct {
    pub fn end(_: Forgot) void {
        forgetAll();
    }
};

/// Every window forgotten. For tests.
pub fn forgetAll() void {
    const gpa = mem_meter.base();
    var it = windows.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    windows.clearAndFree(gpa);
}

const testing = std.testing;

test "a string in the answer is always a JSON string, its bytes that are not UTF-8 as U+FFFD (155's review)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std.ArrayList(u8) = .empty;
    try str(&b, a, "caf\u{00E9} \"q\"");
    try testing.expectEqualStrings("\"caf\u{00E9} \\\"q\\\"\"", b.items);
    b.clearRetainingCapacity();
    try str(&b, a, "x\xc3 \xff\xe2\x80y");
    try testing.expectEqualStrings("\"x\u{FFFD} \u{FFFD}\u{FFFD}\u{FFFD}y\"", b.items);
}

test "a few searches a second, then 429 until the second is over" {
    const meter = mem_meter.useForTest(testing.allocator);
    defer meter.restore();
    const forgot = forgetForTest();
    defer forgot.end();
    for (0..per_second) |_| try testing.expect(admit("7", 1000));
    try testing.expect(!admit("7", 1500));
    // Another person's searches are their own.
    try testing.expect(admit("8", 1500));
    try testing.expect(admit("7", 2000));
}

test "an excerpt is cut on a character's edge, never inside one, and says where it was cut (metal-vmm QUEUE 157(d))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = "\u{00E9}" ** 60; // 120 bytes, two a character
    const ex = try excerptOf(a, e ++ " word " ++ e, "word");
    try testing.expectEqualStrings("word", ex.mark);
    try testing.expect(std.unicode.utf8ValidateSlice(ex.before) and std.unicode.utf8ValidateSlice(ex.after));
    try testing.expect(std.mem.startsWith(u8, ex.before, "\u{2026}") and std.mem.endsWith(u8, ex.after, "\u{2026}"));
    // Short: whole, nothing cut.
    const whole = try excerptOf(a, "a Word here", "word");
    try testing.expectEqualStrings("a ", whole.before);
    try testing.expectEqualStrings("Word", whole.mark);
    try testing.expectEqualStrings(" here", whole.after);
}

test "an excerpt of a word that begins with a stray continuation byte never starts past it (the review of 157)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The tokenizer counts any byte >= 0x80 as a word's; nothing checks a
    // message's bytes on the way in. The cut's start crossed the word.
    const ex = try excerptOf(a, "\x80\x80ab rest", "\x80\x80ab");
    try testing.expectEqualStrings("", ex.before);
    try testing.expectEqualStrings("\x80\x80ab", ex.mark);
    const mid = try excerptOf(a, "x" ** 100 ++ " \x80\x80ab", "\x80\x80ab");
    try testing.expectEqualStrings("\x80\x80ab", mid.mark);
}

test "the rate limit's second: its last millisecond still refuses, the next admits" {
    const meter = mem_meter.useForTest(testing.allocator);
    defer meter.restore();
    const forgot = forgetForTest();
    defer forgot.end();
    for (0..per_second - 1) |_| try testing.expect(admit("9", 1000));
    try testing.expect(admit("9", 1999)); // the last of the second's share
    try testing.expect(!admit("9", 1999));
    try testing.expect(admit("9", 2000));
}

test "an excerpt: a match at offset 0 and one that ends the text are cut nowhere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try excerptOf(a, "word then", "word");
    try testing.expectEqualStrings("", first.before);
    try testing.expectEqualStrings("word", first.mark);
    try testing.expectEqualStrings(" then", first.after);
    const last = try excerptOf(a, "then word", "word");
    try testing.expectEqualStrings("then ", last.before);
    try testing.expectEqualStrings("word", last.mark);
    try testing.expectEqualStrings("", last.after);
    const only = try excerptOf(a, "word", "word");
    try testing.expectEqualStrings("", only.before);
    try testing.expectEqualStrings("word", only.mark);
    try testing.expectEqualStrings("", only.after);
}

test "an excerpt: a match excerpt_pad bytes in keeps all before it, one byte further is cut" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at = "b" ** (excerpt_pad - 1) ++ " ";
    try testing.expectEqualStrings(at, (try excerptOf(a, at ++ "word", "word")).before);
    const past = "b" ** excerpt_pad ++ " ";
    try testing.expectEqualStrings("\u{2026}" ++ past[1..], (try excerptOf(a, past ++ "word", "word")).before);
}

test "an excerpt: excerpt_pad bytes after the match are kept whole, one byte more is cut" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at = " " ++ "b" ** (excerpt_pad - 1);
    try testing.expectEqualStrings(at, (try excerptOf(a, "word" ++ at, "word")).after);
    const past = " " ++ "b" ** excerpt_pad;
    try testing.expectEqualStrings(past[0..excerpt_pad] ++ "\u{2026}", (try excerptOf(a, "word" ++ past, "word")).after);
}
