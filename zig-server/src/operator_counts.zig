//! operator_counts: **THE OPERATOR'S COUNTS, ONE TABLE** (/admin/host, a
//! row a kind): each kind's count since boot and the last one's words, as
//! whoever counted it wrote them: the Roc chat through Host.count!
//! (chat_router.zig), and the Zig's own readers of the same files
//! (chat_paths.channelRosters, chat_codec.decodeChatFile). Process-lifetime
//! state and no decision: what to count and what to say is the counter's.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// What is counted. Every kind of Host.roc's `count!` is one of these by
/// name (chat_router.zig's `countOf` will not compile otherwise).
pub const Kind = enum {
    dropped_announcement,
    dropped_feed_entry,
    dropped_recent_row,
    fanout_failure,
    malformed_channel,
    refused_block,
};

/// The last one's words are kept to their first this many bytes.
const last_max = 192;

const Row = struct {
    n: usize = 0,
    len: usize = 0,
    last: [last_max]u8 = undefined,
};

var rows: std.EnumArray(Kind, Row) = .initFill(.{});

/// `kind` counted once more, its words `parts` joined and kept as the last
/// one's.
pub fn count(kind: Kind, parts: []const []const u8) void {
    const r = rows.getPtr(kind);
    r.n += 1;
    r.len = 0;
    for (parts) |p| {
        const n = @min(p.len, last_max - r.len);
        @memcpy(r.last[r.len..][0..n], p[0..n]);
        r.len += n;
    }
}

/// How many of `kind` were counted since boot.
pub fn counted(kind: Kind) usize {
    return rows.get(kind).n;
}

/// The last `kind`'s words ("" before the first).
pub fn last(kind: Kind) []const u8 {
    const r = rows.getPtr(kind);
    return r.last[0..r.len];
}

/// `kind`'s row as /admin/host says it: none, or the count and the last
/// one's words.
pub fn text(alloc: Alloc, kind: Kind) ![]const u8 {
    if (counted(kind) == 0) return "none";
    return std.fmt.allocPrint(alloc, "{d}; the last: {s}", .{ counted(kind), last(kind) });
}

/// Every count back to none, so a test's rows are its own.
pub fn forgetForTest() void {
    rows = .initFill(.{});
}

test "a kind is none until counted; then its count and its last words, joined and cut at the cap; each kind its own" {
    forgetForTest();
    defer forgetForTest();
    try std.testing.expectEqualStrings("none", try text(std.testing.allocator, .refused_block));
    count(.malformed_channel, &.{ "#", "Abad" });
    count(.malformed_channel, &.{ "#", "bad" });
    const said = try text(std.testing.allocator, .malformed_channel);
    defer std.testing.allocator.free(said);
    try std.testing.expectEqualStrings("2; the last: #bad", said);
    try std.testing.expectEqual(@as(usize, 0), counted(.refused_block));
    const xs: [150]u8 = @splat('x');
    const ys: [150]u8 = @splat('y');
    count(.refused_block, &.{ &xs, &ys });
    try std.testing.expectEqualStrings(&xs, last(.refused_block)[0..150]);
    try std.testing.expectEqualStrings(ys[0..42], last(.refused_block)[150..]);
}
