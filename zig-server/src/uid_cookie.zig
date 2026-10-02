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
//! neither cookie's MAC can pass as the other's. It does not expire: for a
//! player it is the only identity, and expiring it would lose their games.
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
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const store = @import("store.zig");
const users = @import("users.zig");
const player = @import("player.zig");
const game_limits = @import("game_limits.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const cookie_name = "gopher_uid";
const label = "gopher_uid\n";

/// How long the window for unsigned cookies stays open, from its first use.
pub const window_seconds: i64 = 30 * 24 * 60 * 60;

// ── the crypto, pure ─────────────────────────────────────────────────────────

/// An id this cookie may carry: digits (a member or a guest), or `p` and
/// digits (a player). Neither holds a `.`, so the value splits plainly.
pub fn validId(id: []const u8) bool {
    const digits = if (id.len > 1 and id[0] == 'p') id[1..] else id;
    if (digits.len == 0 or digits.len > 20) return false;
    for (digits) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn mac(secret: []const u8, id: []const u8, issued: []const u8, out: *[HmacSha256.mac_length]u8) void {
    var ctx = HmacSha256.init(secret);
    ctx.update(label);
    ctx.update(id);
    ctx.update("\n");
    ctx.update(issued);
    ctx.final(out);
}

/// The cookie's value for `id`, issued at `issued_unix`.
pub fn sign(alloc: Alloc, secret: []const u8, id: []const u8, issued_unix: i64) ![]const u8 {
    const issued = try std.fmt.allocPrint(alloc, "{d}", .{issued_unix});
    var m: [HmacSha256.mac_length]u8 = undefined;
    mac(secret, id, issued, &m);
    var enc: [b64.Encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ id, issued, b64.Encoder.encode(&enc, &m) });
}

/// The id a signed value carries, or null.
pub fn verify(secret: []const u8, value: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, value, '.');
    const id = it.next() orelse return null;
    const issued = it.next() orelse return null;
    const m64 = it.next() orelse return null;
    if (it.next() != null or !validId(id)) return null;
    _ = std.fmt.parseInt(i64, issued, 10) catch return null;
    var want: [HmacSha256.mac_length]u8 = undefined;
    mac(secret, id, issued, &want);
    var got: [HmacSha256.mac_length]u8 = undefined;
    b64.Decoder.decode(&got, m64) catch return null;
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, want, got)) return null;
    return id;
}

/// The Set-Cookie header value for a signed id.
pub fn header(alloc: Alloc, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ cookie_name, value, 60 * 60 * 24 * 365 });
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
    const secret = (try users.sessionSecret(io, alloc)) orelse return null;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    try store.write(io, alloc, try markerPath(alloc, id), marker, .{});
    return try header(alloc, try sign(alloc, secret, id, now));
}

fn markerPath(alloc: Alloc, id: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ player.player_root, id, "signed" });
}

/// Whether `id`'s unsigned spelling is refused for good: marked, and not a
/// re-sign still inside its grace. A marker that will not read is refused.
fn isMarked(io: Io, alloc: Alloc, id: []const u8) bool {
    const p = markerPath(alloc, id) catch return true;
    if (!store.has(io, alloc, p)) return false;
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
    if (users.principalAuthorized(io, alloc, id)) return false; // a member or an agent: never
    if (isMarked(io, alloc, id)) return false;
    const row = std.fs.path.join(alloc, &.{ player.player_root, id, "name" }) catch return false;
    if (!store.has(io, alloc, row) and !users.principalExists(io, alloc, id)) return false;
    return windowOpen(io, alloc);
}

/// The id this request's `gopher_uid` names, signed; null when it names no
/// one. **AN UNSIGNED COOKIE NEVER NAMES ANYONE HERE,** window or not: the
/// router re-signs an honoured one on a GET before any handler runs
/// (`reissue`), so a handler only ever sees a signed id. A POST, which is
/// never redirected, with the unsigned spelling is no one, so the hole is
/// not open to anyone who skips the GET that would close it.
pub fn resolve(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    const value = (try http.cookie(req, alloc, cookie_name)) orelse return null;
    const secret = (try users.sessionSecret(io, alloc)) orelse return null;
    if (verify(secret, value)) |id| return id;
    // **AFTER A CHANGE OF SECRET**, a player's cookie signed with the old one
    // still names them for the days the change allowed (users.rotateSecret);
    // the next GET re-signs it (`reissue`).
    if (try users.previousSecret(io, alloc)) |prev| return verify(prev, value);
    return null;
}

pub const Reissue = union(enum) {
    /// The Set-Cookie for the signed cookie: the router redirects with it.
    cookie: []const u8,
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
    const value = (try http.cookie(req, alloc, cookie_name)) orelse return null;
    const secret = (try users.sessionSecret(io, alloc)) orelse return null;
    if (verify(secret, value)) |_| return null;
    // Signed with the secret before a change, and still taken: re-signed
    // with the current one. It was validly signed, so it is not counted.
    if (try users.previousSecret(io, alloc)) |prev| if (verify(prev, value)) |id| {
        return .{ .cookie = (try issue(io, alloc, id)) orelse return null };
    };
    if (!legacyHonoured(io, alloc, value)) return null;
    if (try game_limits.admitResign(io, client)) |r| return .{ .refused = r };
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const marker = try std.fmt.allocPrint(alloc, "{d}\n", .{now});
    return .{ .cookie = (try issueMarked(io, alloc, value, marker)) orelse return null };
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
    try testing.expectEqualStrings("p3", verify(secret, v).?);
    const m = try sign(a, secret, "12", 1);
    try testing.expectEqualStrings("12", verify(secret, m).?);
    // Another secret, another id, another time, a cut MAC, extra parts.
    try testing.expect(verify("another secret entirely, also long enough", v) == null);
    var other = try a.dupe(u8, v);
    other[1] = '4'; // p4
    try testing.expect(verify(secret, other) == null);
    for ([_][]const u8{ "p3", "p3.1790000000", "p3.1790000000.", "p3.x.abc", "../1.1.abc", "" }) |bad|
        try testing.expect(verify(secret, bad) == null);
    const extra = try std.fmt.allocPrint(a, "{s}.more", .{v});
    try testing.expect(verify(secret, extra) == null);
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
    try testing.expect(verify(secret, forged) == null);
}

test "ids the cookie may carry" {
    for ([_][]const u8{ "1", "12", "p1", "p123" }) |ok| try testing.expect(validId(ok));
    for ([_][]const u8{ "", "p", "P3", "p3x", "x", "1.2", "../1", "p-1" }) |bad| try testing.expect(!validId(bad));
}
