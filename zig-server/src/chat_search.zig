//! chat_search: search across every conversation a person can see, the
//! server side (metal-vmm QUEUE 155(d)). Two routes, JSON, members only (the
//! /chat gate):
//!
//!   GET /chat/search/words?prefix=la    the words beginning so, each with
//!       how many messages hold it, summed over what the viewer can see; at
//!       most `most_words`, the most held first:
//!       {"prefix":"la","unreadable":0,"words":[{"word":"layout","count":3},...]}
//!   GET /chat/search/messages?word=layout   the messages holding the word:
//!       {"word":"layout","matched":N,"unreadable":0,"messages":[{"conv":"/chat/c/1_2",
//!       "kind":"dm","sid":..,"id":..,"from":..,"date":..,"markdown":..},...]}
//!       at most `most_messages` listed, every one counted.
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
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const chat = @import("chat.zig");
const chat_store = @import("chat_store.zig");
const search_index = @import("search_index.zig");
const tokens = @import("search_tokens.zig");
const mem_meter = @import("mem_meter.zig");

const Request = std.http.Server.Request;

pub const most_words = 20;
pub const most_messages = 500;
pub const per_second = 5;
/// The longest key read: a word longer than this is never typed.
pub const max_key = 256;

/// `rest` is the path after "/chat/search".
pub fn handle(req: *Request, io: Io, alloc: Alloc, uid: []const u8, rest: []const u8) !void {
    const words_route = std.mem.eql(u8, rest, "/words");
    if (!words_route and !std.mem.eql(u8, rest, "/messages")) return http.notFound(req);
    if (req.head.method != .GET) return http.methodNotAllowed(req);
    if (!admit(uid, nowMs(io))) {
        return req.respond("{\"error\":\"too many searches; wait a second\"}", .{ .status = .too_many_requests, .extra_headers = &.{http.json_ct} });
    }
    const raw = http.queryValue(try http.target(req, alloc), if (words_route) "prefix" else "word") orelse "";
    var buf: [max_key]u8 = undefined;
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
        try b.print(alloc, ",\"unreadable\":{d},\"words\":[", .{idx.unreadableFor(reach)});
        for (got, 0..) |w, i| {
            if (i > 0) try b.append(alloc, ',');
            try b.appendSlice(alloc, "{\"word\":");
            try str(&b, alloc, w.word);
            try b.print(alloc, ",\"count\":{d}}}", .{w.count});
        }
    } else {
        const f = if (key.len < tokens.min_len) search_index.Found{ .hits = &.{}, .matched = 0 } else try idx.messagesFor(alloc, reach, key, most_messages);
        try b.appendSlice(alloc, "{\"word\":");
        try str(&b, alloc, key);
        try b.print(alloc, ",\"matched\":{d},\"unreadable\":{d},\"messages\":[", .{ f.matched, idx.unreadableFor(reach) });
        for (f.hits, 0..) |h, i| {
            if (i > 0) try b.append(alloc, ',');
            const fields = [_][2][]const u8{
                .{ "{\"conv\":", h.conv.base },
                .{ ",\"kind\":", @tagName(h.conv.kind) },
                .{ ",\"sid\":", h.msg.sid },
                .{ ",\"id\":", h.msg.id },
                .{ ",\"from\":", h.msg.from },
                .{ ",\"date\":", h.msg.date },
                .{ ",\"markdown\":", h.msg.markdown },
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
    const prev = mem_meter.replace(testing.allocator);
    defer _ = mem_meter.replace(prev);
    defer forgetAll();
    for (0..per_second) |_| try testing.expect(admit("7", 1000));
    try testing.expect(!admit("7", 1500));
    // Another person's searches are their own.
    try testing.expect(admit("8", 1500));
    try testing.expect(admit("7", 2000));
}
