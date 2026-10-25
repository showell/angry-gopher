//! decimal: a number written as plain decimal digits, and nothing else.
//!
//! **THE ONE WAY CHAT READS A NUMBER IT WROTE OR NAMED**: a message's number
//! in its id (`<sid>_<n>`), a `.count` sidecar's fields, a reaction's `msg`, a
//! `general<N>` topic, an account's directory, a Range header's byte offsets.
//! Zig's `std.fmt.parseInt` also takes a sign and `_` between digits (`+5`,
//! `1_0` is 10), so an id like `topic_1_0` read as message 10, a second
//! spelling of one number. Here a number has one spelling (leading zeros
//! aside, which nothing writes): one or more of `0`-`9`, no sign, no `_`, no
//! space, and it fits in `T`.

const std = @import("std");

/// `s` as a `T`, or null when it is not one or more decimal digits, or does
/// not fit.
///
/// **NAMED `parseInt` ON PURPOSE**: webbox's edge_sites finds every place a
/// request's number is parsed by a call of that name, and the request-edges
/// test (router_edges_test.zig) covers each with a request at its type's
/// edges. Called by this name, every caller stays a site it sees.
pub fn parseInt(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    var n: T = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = std.math.mul(T, n, 10) catch return null;
        n = std.math.add(T, n, @intCast(c - '0')) catch return null;
    }
    return n;
}

const testing = std.testing;

test "plain digits, and only plain digits" {
    try testing.expectEqual(@as(?usize, 0), parseInt(usize, "0"));
    try testing.expectEqual(@as(?usize, 10), parseInt(usize, "10"));
    try testing.expectEqual(@as(?usize, 7), parseInt(usize, "007"));
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), parseInt(u64, "18446744073709551615"));
    for ([_][]const u8{ "", "+5", "-0", "-1", "1_0", "1__0", " 1", "1 ", "0x10", "1e3", "١" }) |s| {
        try testing.expectEqual(@as(?usize, null), parseInt(usize, s));
    }
    // Too big for the type: not a number of that type.
    try testing.expectEqual(@as(?u64, null), parseInt(u64, "18446744073709551616"));
    try testing.expectEqual(@as(?u8, null), parseInt(u8, "256"));
    try testing.expectEqual(@as(?i64, 42), parseInt(i64, "42"));
}
