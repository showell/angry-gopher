//! chat_search: what search keeps in Zig (metal-vmm QUEUE 155(d), 281, 282).
//! Both routes, /chat/search/words and /chat/search/messages, are the
//! Roc's (roc-webbox chat/main.roc `search_words!`, `search_messages!`;
//! chat/Search.roc): the query, the key, the excerpt and the JSON. The host
//! answers them from here and the index (chat_router.zig's `admitOf`,
//! `searchWords`, `searchMessages`):
//!
//! **A CRUDE RATE LIMIT** (Steve): `per_second` searches a second per
//! person, both routes together, which debounced typing never meets; past
//! it, 429 (`admit`).
//!
//! **AN EXCERPT'S WINDOW, AND ITS COST** (`excerptWindow`, `excerptCost`):
//! the bytes of a hit the Roc cuts its excerpt from, and what the index's
//! walk charges against `most_bytes`, so a message of a megabyte never
//! crosses whole.

const std = @import("std");
const chat = @import("chat.zig");
const search_index = @import("search_index.zig");
const mem_meter = @import("webbox").mem_meter;

/// Bytes of a message either side of the marked word in its excerpt.
pub const excerpt_pad = 90;
pub const per_second = 5;
/// The most bytes of message text one answer lists, as JSON writes it
/// (`search_index.jsonCost`; a doc posted to chat is one message of up to
/// 1 MiB): past it the listing stops, every match still counted (the box's
/// review of 155, and the review of its fix).
pub const most_bytes = 2 << 20;

/// **THE EXCERPT'S WINDOW, FOR THE ROC TO CUT** (metal-vmm QUEUE 282): where
/// the word is (`search_index.wordAt`), and the message's bytes its excerpt
/// can reach: `excerpt_pad` either side of the word and the one byte past
/// (a cut looks there), or, with no word found, the first `2 *
/// excerpt_pad` and the one past. The Roc cuts them on a character's edge
/// and marks the cuts (roc-webbox chat/Search.roc `excerpt`), so a
/// message of a megabyte never crosses whole.
pub const ExcerptWindow = struct { bytes: []const u8, start: usize, at: ?usize };

pub fn excerptWindow(md: []const u8, key: []const u8) ExcerptWindow {
    if (search_index.wordAt(md, key)) |at| {
        const lo = at -| excerpt_pad;
        const hi = @min(md.len, at + key.len + excerpt_pad);
        return .{ .bytes = md[lo..@min(md.len, hi + 1)], .start = lo, .at = at };
    }
    return .{ .bytes = md[0..@min(md.len, 2 * excerpt_pad + 1)], .start = 0, .at = null };
}

/// What a message's excerpt costs as JSON, at most: the window `excerptOf`
/// cuts, and its two marks of a cut. What the route charges its budget.
pub fn excerptCost(md: []const u8, key: []const u8) usize {
    const at = search_index.wordAt(md, key) orelse 0;
    const lo = at -| excerpt_pad;
    const hi = @min(md.len, at + key.len + excerpt_pad);
    return search_index.jsonCost(md[@min(lo, hi)..hi]) + 2 * "\u{2026}".len + 32;
}

// ── the rate limit ───────────────────────────────────────────────────────────

const Window = struct { start_ms: i64, n: u32 };
var windows: std.StringHashMapUnmanaged(Window) = .empty;

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
