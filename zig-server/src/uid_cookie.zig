//! uid_cookie: `__Host-gopher_uid`, signed.
//!
//! `__Host-gopher_uid` names a player (`p<n>`), a member's game identity
//! (digits), or a legacy guest (digits). Its value is
//!
//!     <id>.<issued>.<mac>     mac = base64url(HMAC-SHA256(secret, "gopher_uid\n" id "\n" issued))
//!
//! with the session secret `gopher_auth` uses, under a label of its own so
//! neither cookie's MAC can pass as the other's.
//!
//! **ITS LIFETIME IS `lifetime_secs`, A YEAR FROM ITS SIGNING** (metal-vmm
//! QUEUE 156(f)): the browser's Max-Age, held server-side too, so a cookie
//! kept past it (copied, or stolen) names no one; and an `issued` in the
//! future past `users.clock_skew_secs` names no one. It was said not to
//! expire, but the browser dropped it at the year all along, and nothing
//! re-signed a valid cookie, so a player lost their identity a year after it
//! was signed, active or not. Now a GET re-signs one past half its life
//! (`reissue`; Steve, 2026-10-10): a player who comes back at least every
//! six months keeps who they are.
//!
//! **AFTER THE SECRET CHANGES** (/admin/secret, users.rotateSecret), a cookie
//! signed with the previous secret still names its player for the days the
//! change allowed, and the next GET re-signs it with the new one. That is not
//! counted against the address: it was validly signed.
//!
//! **ONLY THE SIGNED `__Host-` COOKIE NAMES ANYONE.** The cookie was once set
//! in the clear, and then under the bare name `gopher_uid`; an unsigned one
//! was re-signed once inside a window, and the bare name was read until
//! 2026-11-15. Both are gone: a `gopher_uid` cookie, signed or not, names no
//! one, and nothing reads `{player_root}/unsigned-window` or
//! `{player_root}/<id>/signed` any more.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("webbox").http;
const users = @import("users.zig");

const signed = @import("webbox").signed;
const signed_cookie = @import("webbox").signed_cookie;

pub const cookie_name = http.host_prefix ++ "gopher_uid";
const label = "gopher_uid\n";

// ── the crypto, pure ─────────────────────────────────────────────────────────

/// An id this cookie may carry: digits (a member or a guest), or `p` and
/// digits (a player). Neither holds a `.`, so the value splits plainly.
pub fn validId(id: []const u8) bool {
    const digits = if (id.len > 1 and id[0] == 'p') id[1..] else id;
    // Canonical (metal-vmm QUEUE 156(i)): the first digit not zero, as the
    // counters (from 1) write them, so p007 is not p7's other spelling.
    if (digits.len == 0 or digits.len > 20 or digits[0] == '0') return false;
    for (digits) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The cookie's value for `id`, issued at `issued_unix`.
pub fn sign(alloc: Alloc, secret: []const u8, id: []const u8, issued_unix: i64) ![]const u8 {
    return signed.sign(alloc, kind, secret, id, issued_unix);
}

/// How long a signed value names its id, from its signing: the Set-Cookie's
/// Max-Age, and `verify`'s bound.
pub const lifetime_secs: i64 = 365 * 24 * 60 * 60;

/// This cookie's rules for the `webbox` library's signing (signed.zig).
const kind: signed.Kind([]const u8) = .{ .label = label, .lifetime_secs = lifetime_secs, .skew_secs = users.clock_skew_secs, .parse = signed.textIf(validId) };

/// The id a signed value carries at `now_unix`, or null: one past its
/// lifetime, or issued further ahead than a clock's skew, is no one.
pub fn verify(secret: []const u8, value: []const u8, now_unix: i64) ?[]const u8 {
    return signed.verify(kind, secret, value, now_unix);
}

/// The cookie, for webbox's reading and writing of signed cookies.
const cookie: signed_cookie.Cookie([]const u8) = .{ .name = cookie_name, .kind = kind };

fn readNowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// The Set-Cookie header value for a signed id.
pub fn header(alloc: Alloc, value: []const u8) ![]const u8 {
    return signed_cookie.header(cookie, alloc, value);
}

// ── against the disk ─────────────────────────────────────────────────────────
/// A signed Set-Cookie header for `id`, now. Null when there is no session
/// secret: nothing unsigned is ever issued.
pub fn issue(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    if ((try users.loadSessionSecret(io, alloc)) == null) return null;
    return signed_cookie.issue(cookie, io, alloc, users.session_secret_dir, id, readNowUnix(io));
}

/// The id this request's `__Host-gopher_uid` names, signed; null when it
/// names no one.
pub fn resolve(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    // **AFTER A CHANGE OF SECRET**, a player's cookie signed with the old one
    // still names them for the days the change allowed (users.rotateSecret);
    // the next GET re-signs it (`reissue`).
    return switch (try signed_cookie.read(cookie, io, alloc, req, users.session_secret_dir, readNowUnix(io))) {
        .verified => |v| v.id,
        .none, .no_secret, .invalid => null,
    };
}

/// **RE-SIGNED WHEN DUE** (Steve, 2026-10-10): for a GET whose cookie
/// verifies and is past half its life, or signed with the secret before a
/// change and still taken, the Set-Cookie that signs it again; the router
/// answers it with a redirect to the same page. Nothing else re-signs a
/// valid cookie, so a player active all year lost who they were at the
/// year. Null when there is nothing to re-sign.
pub fn reissue(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    if (req.head.method != .GET) return null;
    const now = readNowUnix(io);
    return switch (try signed_cookie.read(cookie, io, alloc, req, users.session_secret_dir, now)) {
        .verified => |v| if (signed_cookie.needsRenewal(cookie, v, now)) try issue(io, alloc, v.text) else null,
        .none, .no_secret, .invalid => null,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a signed value reads back as its id, and nothing else does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator(); // as a request's arena: sign's pieces are not freed one by one
    const secret = "a secret of thirty-two bytes or more, for tests";
    const v = try sign(a, secret, "p3", 1_790_000_000);
    // A frozen vector, from Python's hmac: the format, pinned.
    try testing.expectEqualStrings("p3.1790000000.BTTIGQI3slTgQ_iFwX0DSWx8EhfbUkaIsSuUFfQayP4", v);
    try testing.expectEqualStrings("p3", verify(secret, v, 1_790_000_000).?);
    const m = try sign(a, secret, "12", 1);
    try testing.expectEqualStrings("12", verify(secret, m, 1).?);
    // Another secret, another id, another time, a cut MAC, extra parts.
    try testing.expect(verify("another secret entirely, also long enough", v, 1_790_000_000) == null);
    var other = try a.dupe(u8, v);
    other[1] = '4'; // p4
    try testing.expect(verify(secret, other, 1_790_000_000) == null);
    for ([_][]const u8{ "p3", "p3.1790000000", "p3.1790000000.", "p3.x.abc", "../1.1.abc", "" }) |bad|
        try testing.expect(verify(secret, bad, 1_790_000_000) == null);
    const extra = try std.fmt.allocPrint(a, "{s}.more", .{v});
    try testing.expect(verify(secret, extra, 1_790_000_000) == null);
}

test "a gopher_auth session's MAC does not pass as a gopher_uid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator(); // as a request's arena: sign's pieces are not freed one by one
    const secret = "a secret of thirty-two bytes or more, for tests";
    // users.signSession's MAC covers id \n issued, with no label; the same id
    // and time under this cookie's format must not verify.
    const session = try users.signSession(a, secret, "1", 1_790_000_000);
    var parts = std.mem.splitScalar(u8, session, '.');
    _ = parts.next();
    const issued = parts.next().?;
    const m = parts.next().?;
    const forged = try std.fmt.allocPrint(a, "1.{s}.{s}", .{ issued, m });
    try testing.expect(verify(secret, forged, 1_790_000_000) == null);
}

test "ids the cookie may carry" {
    for ([_][]const u8{ "1", "12", "p1", "p123" }) |ok| try testing.expect(validId(ok));
    for ([_][]const u8{ "", "p", "P3", "p3x", "x", "1.2", "../1", "p-1", "0", "007", "p0", "p007", "+7" }) |bad| try testing.expect(!validId(bad));
    // Twenty digits at most, with or without the p: the edge, both sides.
    try testing.expect(validId(&@as([20]u8, @splat('9'))));
    try testing.expect(validId("p" ++ &@as([20]u8, @splat('9'))));
    try testing.expect(!validId(&@as([21]u8, @splat('9'))));
    try testing.expect(!validId("p" ++ &@as([21]u8, @splat('9'))));
}

test "a value signed rightly over an id the cookie may not carry names no one" {
    // The MAC holds: what is refused is the id. Nothing here signs such an
    // id, but a secret that leaked could, and the id becomes a path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "a secret of thirty-two bytes or more, for tests";
    for ([_][]const u8{ "x", "p3x", "P3", "p", &@as([21]u8, @splat('9')) }) |bad| {
        const v = try sign(a, secret, bad, 1_790_000_000);
        try testing.expect(verify(secret, v, 1_790_000_000) == null);
    }
}

test "a signed value names its id for its lifetime, and not from the future (metal-vmm QUEUE 156(f))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "a secret of thirty-two bytes or more, for tests";
    const t: i64 = 1_790_000_000;
    const v = try sign(a, secret, "p3", t);
    try testing.expectEqualStrings("p3", verify(secret, v, t + lifetime_secs).?);
    try testing.expect(verify(secret, v, t + lifetime_secs + 1) == null);
    try testing.expectEqualStrings("p3", verify(secret, v, t - users.clock_skew_secs).?);
    try testing.expect(verify(secret, v, t - users.clock_skew_secs - 1) == null);
    try testing.expect(verify(secret, try sign(a, secret, "p3", std.math.maxInt(i64)), t) == null);
    try testing.expect(verify(secret, try sign(a, secret, "p3", std.math.minInt(i64)), t) == null);
}

test "an id of 20 digits is a name, not a number: u64's largest and one past it both sign and read back" {
    // validId bounds the digits' count, not their value: no reader of a
    // cookie's id parses it as an integer (users.loadCurrentUserID and
    // player.loadCurrent use it as a path's name), so 18446744073709551616,
    // past u64, is an id like any other of 20 digits.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "a secret of thirty-two bytes or more, for tests";
    for ([_][]const u8{ "18446744073709551615", "18446744073709551616", "p18446744073709551615", "p18446744073709551616" }) |id| {
        try testing.expect(validId(id));
        try testing.expectEqualStrings(id, verify(secret, try sign(a, secret, id, 1_790_000_000), 1_790_000_000).?);
    }
}
