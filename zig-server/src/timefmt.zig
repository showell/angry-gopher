//! timefmt: shared civil-date + timestamp formatting. Extracted so both the
//! game's Eastern-time list formatting (game.zig) and chat's RFC3339 message
//! timestamps (chat_store.zig) share ONE Howard-Hinnant civil-date conversion
//! instead of carrying private copies.

const std = @import("std");

pub const Civil = struct { year: i64, month: u32, day: u32 };

/// civilFromDays converts days-since-1970-01-01 to a civil date (Howard
/// Hinnant's algorithm; valid across the full range).
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0,399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0,365]
    const mp = @divFloor(5 * doy + 2, 153); // [0,11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1,31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1,12]
    return .{ .year = y + @as(i64, if (m <= 2) 1 else 0), .month = @intCast(m), .day = @intCast(d) };
}

/// formatDateUTC renders Unix seconds as `2026-06-19` (UTC) — the docs/post
/// session-id fallback when a conversation has no existing session yet.
pub fn formatDateUTC(alloc: std.mem.Allocator, unix_secs: i64) ![]u8 {
    const c = civilFromDays(@divFloor(unix_secs, 86400));
    return std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2}", .{ c.year, c.month, c.day });
}

/// formatRFC3339UTC renders Unix seconds as `2026-06-19T14:34:07Z` — chat stores
/// it as the `date:` header and emits it as the wire `at`.
pub fn formatRFC3339UTC(alloc: std.mem.Allocator, unix_secs: i64) ![]u8 {
    const days = @divFloor(unix_secs, 86400);
    const tod = unix_secs - days * 86400; // [0, 86399]
    const c = civilFromDays(days);
    const hour: u32 = @intCast(@divFloor(tod, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(tod, 3600), 60));
    const second: u32 = @intCast(@mod(tod, 60));
    return std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        c.year, c.month, c.day, hour, minute, second,
    });
}

/// daysFromCivil is civilFromDays the other way (the same Howard-Hinnant
/// algorithm, inverted).
pub fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const m: i64 = month;
    const mp = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// unixFromRFC3339 reads back what formatRFC3339UTC wrote — `2026-06-19T14:34:07Z`
/// — as Unix seconds, or null for anything else.
///
/// **A DATE THAT WAS RECORDED BEATS A FILE'S MTIME.** /chat/recent orders by
/// this: mtime is two-second granular on FAT16 and nanosecond on ext4, so the
/// two hosts this application runs on could not agree on the order of two
/// messages sent close together — and mtime moves for any write, where the
/// date says when the message was actually sent.
pub fn unixFromRFC3339(text: []const u8) ?i64 {
    if (text.len != 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':' or text[19] != 'Z') return null;
    const num = struct {
        fn at(s: []const u8, start: usize, len: usize) ?i64 {
            return std.fmt.parseInt(i64, s[start..][0..len], 10) catch null;
        }
    };
    const year = num.at(text, 0, 4) orelse return null;
    const month = num.at(text, 5, 2) orelse return null;
    const day = num.at(text, 8, 2) orelse return null;
    const hour = num.at(text, 11, 2) orelse return null;
    const minute = num.at(text, 14, 2) orelse return null;
    const second = num.at(text, 17, 2) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return daysFromCivil(year, @intCast(month), @intCast(day)) * 86400 + hour * 3600 + minute * 60 + second;
}

const testing = std.testing;

test "a formatted timestamp reads back as the seconds it was made from" {
    const a = testing.allocator;
    for ([_]i64{ 0, 1, 86399, 86400, 951782400, 1789600584, 4102444800 }) |secs| {
        const text = try formatRFC3339UTC(a, secs);
        defer a.free(text);
        try testing.expectEqual(secs, unixFromRFC3339(text).?);
    }
}

test "the two conversions are inverses, including before year one" {
    // @divFloor already floors; the `- 146096` and `- 399` these two carried
    // were the adjustment a TRUNCATING divide needs, so the negative era was
    // floored twice and every day from 0000-02-29 back was off by one.
    var days: i64 = -800000;
    while (days < 800000) : (days += 7) {
        const c = civilFromDays(days);
        try testing.expectEqual(days, daysFromCivil(c.year, c.month, c.day));
    }
    // Year zero was a leap year, and 0000-03-01 is day -719468 by definition
    // of the epoch offset — so the day before it is the 29th.
    const leap = civilFromDays(-719469);
    try testing.expectEqual(@as(i64, 0), leap.year);
    try testing.expectEqual(@as(u32, 2), leap.month);
    try testing.expectEqual(@as(u32, 29), leap.day);
    try testing.expectEqual(@as(i64, -719468), daysFromCivil(0, 3, 1));
}

test "a leap day reads back" {
    const a = testing.allocator;
    const text = try formatRFC3339UTC(a, 1583020801); // 2020-03-01T00:00:01Z
    defer a.free(text);
    try testing.expectEqualStrings("2020-03-01T00:00:01Z", text);
    try testing.expectEqual(@as(i64, 1583020801), unixFromRFC3339(text).?);
    try testing.expectEqual(@as(i64, 1582934401), unixFromRFC3339("2020-02-29T00:00:01Z").?);
}

test "anything that is not that shape is not a date" {
    try testing.expectEqual(@as(?i64, null), unixFromRFC3339(""));
    try testing.expectEqual(@as(?i64, null), unixFromRFC3339("2026-06-19"));
    try testing.expectEqual(@as(?i64, null), unixFromRFC3339("2026-06-19T14:34:07"));
    try testing.expectEqual(@as(?i64, null), unixFromRFC3339("2026-06-19 14:34:07Z"));
    try testing.expectEqual(@as(?i64, null), unixFromRFC3339("2026-13-19T14:34:07Z"));
    try testing.expectEqual(@as(?i64, null), unixFromRFC3339("xxxx-06-19T14:34:07Z"));
}
