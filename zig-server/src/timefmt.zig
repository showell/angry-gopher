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
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
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
