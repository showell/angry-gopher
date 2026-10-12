//! uid_cookie: `gopher_uid`, signed (gopher-metal QUEUE item 51,
//! DESIGN-signed-uid.md; Steve, 2026-10-02: re-identify once).
//!
//! `gopher_uid` names a player (`p<n>`), a member's game identity (digits),
//! or a legacy guest (digits). It was set in the clear, so whoever set it by
//! hand WAS that identity: a player's games, a member's games, a guest's
//! account (REVIEW-request-paths findings 1-2). Now it is
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
//! **COOKIES ALREADY IN BROWSERS ARE RE-IDENTIFIED ONCE.** An unsigned
//! `gopher_uid` is honoured only:
//!   - while the window is open (`{player_root}/unsigned-window` holds the
//!     second it closes: 30 days from the first time it is asked, or sooner
//!     if someone writes an earlier time there, as CUTOVER.md does);
//!   - for an id that is a player or a guest, not a member or an agent;
//!   - and only until that id has been signed once (`{player_root}/<id>/
//!     signed`). The first GET with it is answered with a redirect that
//!     sets the signed cookie and writes the marker; from then on the
//!     unsigned spelling is refused, so the owner's first visit closes the
//!     hole for that id. Nothing else honours it: a POST with it is no one.
//! A member is never re-identified by an unsigned cookie: their games follow
//! their session instead (player.current).

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("webbox").http;
const store = @import("webbox").store;
const users = @import("users.zig");
const player = @import("player.zig");
const game_limits = @import("game_limits.zig");

const signed = @import("webbox").signed;
const signed_cookie = @import("webbox").signed_cookie;

pub const cookie_name = http.host_prefix ++ "gopher_uid";
/// Its name before the `__Host-` prefix (metal-vmm QUEUE 167.5): read when a
/// request has none of the new name, and moved to it on the next GET.
pub const legacy_cookie_name = "gopher_uid";
const label = "gopher_uid\n";

/// How long the window for unsigned cookies stays open, from its first use.
pub const window_seconds: i64 = 30 * 24 * 60 * 60;

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
const kind: signed.Kind = .{ .label = label, .lifetime_secs = lifetime_secs, .skew_secs = users.clock_skew_secs, .validId = validId };

/// The id a signed value carries at `now_unix`, or null: one past its
/// lifetime, or issued further ahead than a clock's skew, is no one.
pub fn verify(secret: []const u8, value: []const u8, now_unix: i64) ?[]const u8 {
    return signed.verify(kind, secret, value, now_unix);
}

/// The cookie, for webbox's reading and writing of signed cookies.
const cookie: signed_cookie.Cookie = .{ .name = cookie_name, .legacy_name = legacy_cookie_name, .kind = kind };

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// The Set-Cookie header value for a signed id.
pub fn header(alloc: Alloc, value: []const u8) ![]const u8 {
    return signed_cookie.header(cookie, alloc, value);
}

// ── against the disk ─────────────────────────────────────────────────────────

/// A signed Set-Cookie header for `id`, now, and the id marked as signed so
/// its unsigned spelling is refused from now on. Null when there is no
/// session secret: nothing unsigned is ever issued.
pub fn issue(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    return issueMarked(io, alloc, id, "");
}

/// **A RE-SIGN CAN BE ASKED AGAIN, BRIEFLY.** The marker is written before
/// the answer leaves, and if the signed cookie never reached the browser
/// (the tab closed, the connection dropped), the owner had neither cookie
/// (gopher-metal REVIEW-signed-uid-and-limits.md, finding 3). So a re-sign's
/// marker holds the second it was written, and the same unsigned cookie is
/// honoured again for `grace_seconds` after it: a reload recovers. A marker
/// written for a new player or a login holds nothing, and has no grace:
/// those ids never had an unsigned cookie to come back with.
pub const grace_seconds: i64 = 10 * 60;

fn issueMarked(io: Io, alloc: Alloc, id: []const u8, marker: []const u8) !?[]const u8 {
    if ((try users.sessionSecret(io, alloc)) == null) return null;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    try store.write(io, alloc, try markerPath(alloc, id), marker, .{});
    return signed_cookie.issue(cookie, io, alloc, users.session_secret_dir, id, now);
}

fn markerPath(alloc: Alloc, id: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ player.player_root, id, "signed" });
}

/// Whether `id`'s unsigned spelling is refused for good: marked, and not a
/// re-sign still inside its grace. A marker that will not read is refused.
fn isMarked(io: Io, alloc: Alloc, id: []const u8) bool {
    const p = markerPath(alloc, id) catch return true;
    // absent-ok: fails closed: a marker that cannot be looked at refuses the unsigned spelling.
    if (!(store.has(io, alloc, p) catch return true)) return false;
    // absent-ok: fails closed, as above.
    const raw = store.read(io, alloc, p, .limited(64)) catch return true;
    const at = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return true;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return now - at >= grace_seconds;
}

/// Whether unsigned cookies are still honoured. The window opens the first
/// time this is asked and closes `window_seconds` later; a time written
/// into the file sooner closes it then. A file that will not read or parse
/// closes it.
pub fn windowOpen(io: Io, alloc: Alloc) bool {
    const path = std.fs.path.join(alloc, &.{ player.player_root, "unsigned-window" }) catch return false;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    // absent-ok: fails closed: a window that will not read is shut.
    const raw = store.readOrEmpty(io, alloc, path, .limited(64)) catch return false;
    if (raw.len == 0) {
        const body = std.fmt.allocPrint(alloc, "{d}\n", .{now + window_seconds}) catch return false;
        store.replace(io, alloc, path, body, .{}) catch return false;
        return true;
    }
    const ends = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return false;
    return now < ends;
}

/// Whether an unsigned cookie naming `id` is honoured: see the file header.
fn legacyHonoured(io: Io, alloc: Alloc, id: []const u8) bool {
    if (!validId(id)) return false;
    // absent-ok: fails closed: a member or an agent is never honoured, and one that cannot be told is taken as one.
    if (users.principalAuthorized(io, alloc, id) catch true) return false;
    if (isMarked(io, alloc, id)) return false;
    const row = std.fs.path.join(alloc, &.{ player.player_root, id, "name" }) catch return false;
    // absent-ok: fails closed: a player that cannot be looked up is not honoured.
    if (!(store.has(io, alloc, row) catch return false) and !(users.principalExists(io, alloc, id) catch return false)) return false;
    return windowOpen(io, alloc);
}

/// The id this request's `gopher_uid` names, signed; null when it names no
/// one. **AN UNSIGNED COOKIE NEVER NAMES ANYONE HERE,** window or not: the
/// router re-signs an honoured one on a GET before any handler runs
/// (`reissue`), so a handler only ever sees a signed id. A POST, which is
/// never redirected, with the unsigned spelling is no one, so the hole is
/// not open to anyone who skips the GET that would close it.
pub fn resolve(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    // **AFTER A CHANGE OF SECRET**, a player's cookie signed with the old one
    // still names them for the days the change allowed (users.rotateSecret);
    // the next GET re-signs it (`reissue`).
    return switch (try signed_cookie.read(cookie, io, alloc, req, users.session_secret_dir, nowUnix(io))) {
        .verified => |v| v.id,
        .none, .no_secret, .invalid => null,
    };
}

pub const Reissue = union(enum) {
    /// The Set-Cookie for the signed cookie: the router redirects with it,
    /// and clears the legacy-named one when that was what came (metal-vmm
    /// QUEUE 170.8: moved, never left to be read again, and a browser that
    /// drops the new one over plain http is a new visitor, not a loop).
    cookie: struct { set: []const u8, clear_legacy: bool },
    /// This address has had its share of re-signs this hour.
    refused: game_limits.Refusal,
};

/// **THE ONE RE-IDENTIFICATION.** For a GET carrying an unsigned cookie the
/// window still honours: the Set-Cookie for the signed one, with the id
/// marked so the unsigned spelling is refused from now on. The router
/// answers it with a redirect to the same page. **Counted per address**
/// (`client`, game_limits.admitResign), so one address cannot sweep every
/// legacy id. Null when there is nothing to re-sign.
pub fn reissue(io: Io, alloc: Alloc, req: *std.http.Server.Request, client: ?[]const u8) !?Reissue {
    if (req.head.method != .GET) return null;
    const now = nowUnix(io);
    switch (try signed_cookie.read(cookie, io, alloc, req, users.session_secret_dir, now)) {
        // No cookie, or no secret: nothing re-signed, and nothing counted
        // against the address.
        .none, .no_secret => return null,
        // **PAST HALF ITS LIFE, RE-SIGNED** (Steve, 2026-10-10): nothing
        // else re-signs a valid cookie, so a player active all year lost
        // who they were at the year. And signed with the secret before a
        // change, and still taken: re-signed with the current one. Validly
        // signed either way, so not counted against the address.
        .verified => |v| {
            if (!signed_cookie.needsRenewal(cookie, v, now)) return null;
            return .{ .cookie = .{ .set = (try issue(io, alloc, v.id)) orelse return null, .clear_legacy = v.legacy } };
        },
        // Perhaps a legacy unsigned spelling: below.
        .invalid => {},
    }
    // One unsigned value only: of several, which is meant cannot be told.
    // Never issued unsigned under the new name, and never read after the
    // legacy names' end date (170.8's cold review).
    if (http.namesNow(now) >= http.legacy_names_until_unix) return null;
    const value = switch (try http.cookie(req, alloc, legacy_cookie_name)) {
        .one => |v| v,
        .none, .several => return null,
    };
    if (!legacyHonoured(io, alloc, value)) return null;
    if (try game_limits.admitResign(io, client)) |r| return .{ .refused = r };
    const marker = try std.fmt.allocPrint(alloc, "{d}\n", .{now});
    return .{ .cookie = .{ .set = (try issueMarked(io, alloc, value, marker)) orelse return null, .clear_legacy = true } };
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
    try testing.expect(validId("9" ** 20));
    try testing.expect(validId("p" ++ "9" ** 20));
    try testing.expect(!validId("9" ** 21));
    try testing.expect(!validId("p" ++ "9" ** 21));
}

test "a value signed rightly over an id the cookie may not carry names no one" {
    // The MAC holds: what is refused is the id. Nothing here signs such an
    // id, but a secret that leaked could, and the id becomes a path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "a secret of thirty-two bytes or more, for tests";
    for ([_][]const u8{ "x", "p3x", "P3", "p", "9" ** 21 }) |bad| {
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
    // cookie's id parses it as an integer (users.currentUserID and
    // player.current use it as a path's name), so 18446744073709551616,
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
