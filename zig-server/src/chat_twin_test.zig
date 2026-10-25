//! **THE ROC CHAT'S PURE MODULES, EACH HELD TO ITS ZIG TWIN** (roc-webbox
//! docs/ROC-CHAT.md C1, C2): every Roc function that will replace a Zig one
//! is called here beside it, through the test-only seam (`roc_chat_twin`,
//! roc-webbox chat/twin.roc), on the same inputs, many of them: the
//! answers must be the same bytes. A module of the Roc chat moves to
//! production only with its twin here green.

const std = @import("std");
const testing = std.testing;
const twin = @import("roc_chat_twin");
const timefmt = @import("timefmt.zig");

/// chat/twin.roc's numbers.
const Fn = enum(u8) {
    time_rfc3339 = 1,
    time_date = 2,
    time_unix_from_rfc3339 = 3,
};

/// One Roc call's results, in `a`.
fn roc(a: std.mem.Allocator, f: Fn, args: []const []const u8) ![][]u8 {
    return twin.call(a, @backingInt(f), args);
}

/// The Roc's one result, or null when it gave none.
fn roc1(a: std.mem.Allocator, f: Fn, args: []const []const u8) !?[]u8 {
    const got = try roc(a, f, args);
    return switch (got.len) {
        0 => null,
        1 => got[0],
        else => error.TwinGaveMore,
    };
}

/// A difference between the twins, said once and counted.
const Differences = struct {
    count: usize = 0,
    fn add(d: *Differences, comptime fmt: []const u8, args: anytype) void {
        d.count += 1;
        if (d.count <= 10) std.debug.print(fmt ++ "\n", args);
    }
    fn none(d: Differences, compared: usize) !void {
        if (d.count > 0) {
            std.debug.print("{d} of {d} differ\n", .{ d.count, compared });
            return error.TestUnexpectedResult;
        }
    }
};

fn setUp() std.heap.ArenaAllocator {
    twin.use(testing.allocator);
    return std.heap.ArenaAllocator.init(testing.allocator);
}

// ── Time (timefmt.zig) ─────────────────────────────────────────────────────

/// Seconds that try the calendar: the epoch and around it, leap days and
/// centuries (1900, 2000, 2100, 2400), the years Hinnant's eras turn, the
/// far past and future, and a pseudorandom spread between.
fn times(a: std.mem.Allocator) ![]i64 {
    var out: std.ArrayList(i64) = .empty;
    for ([_]i64{ 0, -1, 1, 86399, 86400, -86400, -86401, 951782400, 951868800, 4107542400, 4107456000, 13574563200, -2208988800, -62135596800, -62167219200, 253402300799, 253402300800, 1761400000, 1700000000 }) |t|
        for ([_]i64{ -1, 0, 1 }) |d| try out.append(a, t + d);
    var rng = std.Random.DefaultPrng.init(0x7177e);
    for (0..5000) |_| try out.append(a, rng.random().intRangeAtMost(i64, -62135596800, 253402300799));
    return out.toOwnedSlice(a);
}

test "Time: a message's date and a dated topic's name, for every time tried" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    const ts = try times(a);
    for (ts) |t| {
        const arg = try std.fmt.allocPrint(a, "{d}", .{t});
        const zr = try timefmt.formatRFC3339UTC(a, t);
        const rr = (try roc1(a, .time_rfc3339, &.{arg})).?;
        if (!std.mem.eql(u8, zr, rr)) differ.add("rfc3339({d}): zig {s}, roc {s}", .{ t, zr, rr });
        const zd = try timefmt.formatDateUTC(a, t);
        const rd = (try roc1(a, .time_date, &.{arg})).?;
        if (!std.mem.eql(u8, zd, rd)) differ.add("date({d}): zig {s}, roc {s}", .{ t, zd, rd });
    }
    try differ.none(ts.len * 2);
}

test "Time: a date read back, as written, with a fraction or an offset, and every byte of it damaged" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var texts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "", "Z", "2026-05-28T10:00:00", "2026-05-28t10:00:00z", "2026-05-28T10:00:00.Z", "2026-05-28T10:00:00+0530", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-01-32T00:00:00Z", "2026-01-31T24:00:00Z", "2026-01-31T23:60:00Z", "2026-01-31T23:59:60Z", "2026-01-31T23:59:61Z", "2026-01-31T23:59:59+24:00", "2026-01-31T23:59:59-00:60", "+026-01-31T23:59:59Z", "2026-02-31T00:00:00Z" }) |t| try texts.append(a, t);
    for ((try times(a))[0..400]) |t| {
        const base = try timefmt.formatRFC3339UTC(a, t);
        try texts.append(a, base);
        const stem = base[0 .. base.len - 1];
        for ([_][]const u8{ ".5Z", ".123456789Z", "+05:30", "-08:00", "+00:00", "-23:59", "z", ".Z", "+5:30", "" }) |tail|
            try texts.append(a, try std.mem.concat(a, u8, &.{ stem, tail }));
    }
    // Every byte of one date replaced by each byte that matters to it.
    const one = "2026-06-19T14:34:07.25+05:30";
    for (0..one.len) |i| for ([_]u8{ '0', '9', '-', ':', 'T', 'Z', '+', '.', 'x', 0, 0xff }) |b| {
        const d = try a.dupe(u8, one);
        d[i] = b;
        try texts.append(a, d);
    };
    var differ: Differences = .{};
    for (texts.items) |text| {
        const z = timefmt.unixFromRFC3339(text);
        const r = try roc1(a, .time_unix_from_rfc3339, &.{text});
        const rz: ?i64 = if (r) |s| try std.fmt.parseInt(i64, s, 10) else null;
        if (z != rz) differ.add("unixFromRFC3339(\"{s}\"): zig {?d}, roc {?d}", .{ text, z, rz });
    }
    try differ.none(texts.items.len);
}
