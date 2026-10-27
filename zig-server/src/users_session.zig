//! users_session: who is asking. The signed session cookie (its MAC, its
//! secret and the secret's rotation), the legacy cookie's move to `__Host-`,
//! API keys and bearer parsing, and the resolver that turns a request into a
//! user (split from users.zig by metal-vmm QUEUE 174; the account records
//! stay in users.zig).

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const auth = @import("auth.zig");
const counter = @import("webbox").counter;
const http = @import("webbox").http;
const store = @import("webbox").store;
const uid_cookie = @import("uid_cookie.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;
const site_secret = @import("webbox").site_secret;
const testing = std.testing;
const users = @import("users.zig");
const setUserPassword = users.setUserPassword;
const readAuthFile = users.readAuthFile;
const allocateUser = users.allocateUser;
const userIsAuthorized = users.userIsAuthorized;
const userIsMember = users.userIsMember;
const userExists = users.userExists;
const tmpRoots = users.tmpRoots;
const getUserName = users.getUserName;
const nowUnix = users.nowUnix;
const allDigits = users.allDigits;

const session_max_age_secs: i64 = 365 * 24 * 60 * 60;

/// **HOW FAR AHEAD A COOKIE'S `issued` MAY BE** (metal-vmm QUEUE 156(f)): a
/// clock a little behind the one that signed it. Past this it is refused: an
/// `issued` in the future never expired, whatever the max age.
pub const clock_skew_secs: i64 = 5 * 60;

// ── the resolver ────────────────────────────────────────────────────────────

/// currentUserID resolves the id a request acts as, or "" when there's no valid
/// identity.
pub fn currentUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) ![]const u8 {
    // 1. member session cookie (authoritative).
    if (try sessionUserID(io, alloc, req)) |id| return id;
    // 2. API key.
    if (try apiKeyUserID(io, alloc, req)) |id| return id;
    // 3. guest gopher_uid — only a non-authorized principal that exists, and
    // only signed (an unsigned one is re-signed once by the router's GET, in
    // uid_cookie's window, and is no one here). An unsigned cookie used to be
    // enough, which let anyone set a guest's password. The value is owned by
    // http.cookie, so it survives a later
    // body read.
    if (try uid_cookie.resolve(io, alloc, req)) |uid| {
        if (allDigits(uid) and try userExists(io, alloc, uid) and !try userIsAuthorized(io, alloc, uid)) {
            return uid;
        }
    }
    return "";
}

/// The member session cookie's name (metal-vmm QUEUE 167.5: `__Host-`, so no
/// sibling subdomain can plant one), and its name before, still read when a
/// request has none of the new one; a login sets the new one.
pub const session_cookie = http.host_prefix ++ "gopher_auth";

pub const session_cookie_legacy = "gopher_auth";

/// sessionUserID returns the member id from a valid gopher_auth cookie whose id
/// is still a member. Reading a cookie is what identity does and nothing else
/// needs to: `http.cookie`'s callers are this file and uid_cookie.zig. A head
/// value borrowed past the body read once mis-attributed an authenticated post
/// to the wrong principal, which is why `http.cookie` returns an owned copy.
fn sessionUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    const s = (try sessionRead(io, alloc, req)) orelse return null;
    return s.id;
}

const SessionRead = struct { id: []const u8, value: []const u8, legacy: bool };

/// The session a request carries, verified, and whether under the legacy
/// name (until `http.legacy_names_until_unix`).
fn sessionRead(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?SessionRead {
    const now = nowUnix(io);
    var one: [1][]const u8 = undefined;
    const named = try http.cookieOrLegacy(req, alloc, session_cookie, session_cookie_legacy, http.namesNow(now));
    const values: []const []const u8 = switch (named.values) {
        .none => return null,
        .one => |v| blk: {
            one[0] = v;
            break :blk &one;
        },
        .several => |vs| vs,
    };
    const secret = (try loadSecret(io, alloc)) orelse return null;
    // Of several (a parent domain's beside this site's own), the one that
    // verifies; none, or more than one, is no one (metal-vmm QUEUE 162.4,
    // as signed_cookie.read).
    var verified: ?SessionRead = null; // the one that verified, until a second does
    for (values) |val| if (verifySessionWithSecret(alloc, secret, val, now)) |id| {
        // A legacy-named session signed after the move is a plant: not read.
        if (named.legacy and !legacyTaken(issuedOfSession(val))) continue;
        if (verified != null) return null;
        verified = .{ .id = id, .value = val, .legacy = named.legacy };
    };
    const s = verified orelse return null;
    if (!try userIsMember(io, alloc, s.id)) return null;
    return s;
}

/// Whether a legacy-named value signed at `issued` is read: only one signed
/// before the move (`http.legacy_issued_before_unix`); a later one is a plant.
fn legacyTaken(issued: i64) bool {
    return issued < http.legacy_issued_before_unix;
}

test "a legacy session signed after the move is a plant, not read; one before it is (metal-vmm QUEUE 170.8)" {
    try std.testing.expect(legacyTaken(http.legacy_issued_before_unix - 1));
    try std.testing.expect(!legacyTaken(http.legacy_issued_before_unix));
    try std.testing.expectEqual(@as(i64, 1790000000), issuedOfSession("MQ.1790000000.mac"));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), issuedOfSession("MQ"));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), issuedOfSession("MQ.x.mac"));
}

/// When a session value says it was signed (its middle part); a value that
/// does not say is as new as can be.
fn issuedOfSession(val: []const u8) i64 {
    var it = std.mem.splitScalar(u8, val, '.');
    _ = it.next();
    const t = it.next() orelse return std.math.maxInt(i64);
    return std.fmt.parseInt(i64, t, 10) catch std.math.maxInt(i64);
}

/// **A SESSION UNDER ITS LEGACY NAME IS MOVED ON ITS NEXT GET** (metal-vmm
/// QUEUE 170.8): the signed value, to be set under `session_cookie` (the
/// signature does not name the cookie) while the legacy one is cleared; null
/// when there is nothing to move.
pub fn sessionToMove(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    if (req.head.method != .GET) return null;
    const s = (try sessionRead(io, alloc, req)) orelse return null;
    return if (s.legacy) s.value else null;
}

/// **THE BEARER ONLY** (metal-vmm QUEUE 200): the principal an
/// `Authorization: Bearer` key names, and never a session cookie's, for a
/// route that a page must not be able to drive (the script route).
pub fn bearerUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    return apiKeyUserID(io, alloc, req);
}

/// apiKeyUserID resolves the principal id from an Authorization: Bearer key.
fn apiKeyUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    const key = (try bearerToken(req, alloc)) orelse return null;
    return checkAPIKey(io, alloc, key);
}

// ── session cookie crypto ────────────────────────────────────────────────────

/// sessionMAC writes HMAC-SHA256(secret, id + "\n" + issued) into out.
fn sessionMAC(secret: []const u8, id: []const u8, issued: []const u8, out: *[HmacSha256.mac_length]u8) void {
    var ctx = HmacSha256.init(secret);
    ctx.update(id);
    ctx.update("\n");
    ctx.update(issued);
    ctx.final(out);
}

/// verifySessionWithSecret validates a `base64url(id).issued.base64url(mac)`
/// cookie against `secret` at time `now_unix` (Unix seconds), returning the id
/// or null.
pub fn verifySessionWithSecret(alloc: Alloc, secret: []const u8, val: []const u8, now_unix: i64) ?[]const u8 {
    var it = std.mem.splitScalar(u8, val, '.');
    const p0 = it.next() orelse return null;
    const p1 = it.next() orelse return null;
    const p2 = it.next() orelse return null;
    if (it.next() != null) return null; // exactly 3 parts

    // id = base64url-decoded p0.
    const id = decodeB64(alloc, p0) catch return null;
    const issued = p1;

    // recompute MAC, compare to the decoded presented MAC (32 bytes).
    var computed: [HmacSha256.mac_length]u8 = undefined;
    sessionMAC(secret, id, issued, &computed);
    // A MAC of any other length is no one's, said before it is decoded:
    // decode writes as many bytes as the text holds (signed.zig's verify).
    if ((b64.Decoder.calcSizeForSlice(p2) catch return null) != HmacSha256.mac_length) return null;
    var presented: [HmacSha256.mac_length]u8 = undefined;
    (b64.Decoder.decode(&presented, p2)) catch return null; // wrong charset -> reject
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, computed, presented)) return null;

    // expiry: issued must parse and be within max age.
    const n = std.fmt.parseInt(i64, issued, 10) catch return null;
    if (now_unix -| n > session_max_age_secs) return null;
    if (n -| now_unix > clock_skew_secs) return null;
    return id;
}

/// signSession produces a cookie value for `id` issued at `issued_unix`, signed
/// with `secret`. The secret-parameterized form: signSessionNow wraps it with the
/// live secret, and the gold harness drives it with a synthetic one.
pub fn signSession(alloc: Alloc, secret: []const u8, id: []const u8, issued_unix: i64) ![]const u8 {
    const issued = try std.fmt.allocPrint(alloc, "{d}", .{issued_unix});
    var mac: [HmacSha256.mac_length]u8 = undefined;
    sessionMAC(secret, id, issued, &mac);
    const id_b64 = try encodeB64(alloc, id);
    const mac_b64 = try encodeB64(alloc, &mac);
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ id_b64, issued, mac_b64 });
}

// ── API key (cross-validated compare) ────────────────────────────────────────

/// apiKeyMatches reports whether `presented` is the credential `stored` stands
/// for. Two stored forms: a modern plaintext key ("<id>-<hex>", contains '-')
/// compares constant-time as-is; a legacy bare hash (no '-') matches the
/// sha256-hex of the presented key. Constant-time in both arms. PURE — the Io-free
/// security decision, lifted out of checkAPIKey's file read so it carries its own
/// frozen-vector tests (the api-key peer of verifySessionWithSecret).
pub fn apiKeyMatches(stored: []const u8, presented: []const u8) bool {
    if (std.mem.indexOfScalar(u8, stored, '-') != null) return ctEql(stored, presented);
    var sum: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(presented, &sum, .{});
    const hex = std.fmt.bytesToHex(sum, .lower);
    return ctEql(stored, &hex);
}

/// checkAPIKey resolves the principal id a presented key belongs to, or null. The
/// id is the key's "<id>-" prefix; it must be authorized and its stored api-key
/// must match (apiKeyMatches).
fn checkAPIKey(io: Io, alloc: Alloc, presented: []const u8) !?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, presented, '-') orelse return null;
    const id = presented[0..dash];
    // **A UID, BEFORE IT IS A PATH.** The prefix names {users.auth_root}/<id>/...,
    // and an id with `/` or `..` in it reached other folders' password and
    // api-key files.
    const uid = users.Uid.of(id) orelse return null;
    if (!try userIsAuthorized(io, alloc, id)) return null;

    // absent-ok: fails closed: a key that cannot be read admits no one.
    const stored_opt = readAuthFile(io, alloc, uid, "api-key") catch return null;
    const stored = std.mem.trim(u8, stored_opt orelse return null, " \t\r\n");
    // `id` is a slice into `presented`, which bearerToken already owns (via
    // http.header), so it survives a later body read — no dupe needed here.
    return if (apiKeyMatches(stored, presented)) id else null;
}

// ── registry reads (account store) ───────────────────────────────────────────

/// The session secret, for the other signed cookie (uid_cookie.zig), or null.
pub fn sessionSecret(io: Io, alloc: Alloc) !?[]const u8 {
    return loadSecret(io, alloc);
}

/// The member a valid gopher_auth names, or null: player.zig's way to file a
/// member's games under their session when their gopher_uid is unsigned.
pub fn sessionUser(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    return sessionUserID(io, alloc, req);
}

// ── changing the secret (zig-metal-unikernel QUEUE item 66, SECRET-LEAK.md) ─────────
//
// The secret's files are webbox's (site_secret.zig), in users.session_secret_dir.

/// The secret before the last change, while players' cookies signed with it
/// are still taken (`previous-until`, Unix seconds); null past that, or when
/// there is none. Members' sessions are never checked against it.
pub fn previousSecret(io: Io, alloc: Alloc) !?[]const u8 {
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return site_secret.previous(io, alloc, users.session_secret_dir, now);
}

/// **CHANGES THE SECRET** (site_secret.rotate). The current one becomes the
/// previous one, taken for players' cookies for `players_days` more days (0:
/// not at all). Every member's session ends at once; a player's cookie is
/// re-signed on their next visit inside the days.
pub fn rotateSecret(io: Io, alloc: Alloc, players_days: i64) !void {
    return site_secret.rotate(io, alloc, users.session_secret_dir, players_days);
}

/// The secret (>= 32 bytes), or null. Nothing makes a first secret: it is
/// seeded on disk (README, "Bootstrapping"). Only rotateSecret, from
/// /admin/secret, replaces one that exists.
fn loadSecret(io: Io, alloc: Alloc) !?[]const u8 {
    return site_secret.load(io, alloc, users.session_secret_dir);
}

// ── request parsing ──────────────────────────────────────────────────────────

/// bearerToken extracts the (owned) token from an Authorization: Bearer <token>
/// header. The token is duped by http.header, so slices of it (the "<id>-" prefix
/// in checkAPIKey) survive a later body read.
fn bearerToken(req: *std.http.Server.Request, alloc: Alloc) !?[]const u8 {
    const h = (try http.header(req, alloc, "authorization")) orelse return null;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, h, prefix)) return null;
    const tok = std.mem.trim(u8, h[prefix.len..], " \t");
    return if (tok.len == 0) null else tok;
}

// ── small helpers ────────────────────────────────────────────────────────────

/// ctEql is a constant-time slice compare: unequal lengths short-circuit to
/// false, equal lengths compare in constant time.
fn ctEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

fn decodeB64(alloc: Alloc, s: []const u8) ![]u8 {
    const n = try b64.Decoder.calcSizeForSlice(s);
    const out = try alloc.alloc(u8, n);
    try b64.Decoder.decode(out, s);
    return out;
}

fn encodeB64(alloc: Alloc, s: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, b64.Encoder.calcSize(s.len));
    return b64.Encoder.encode(out, s);
}

// ══ ISSUANCE (login.zig's account-store mechanics) ═══════════════════════════
//
// Everything below WRITES the account store (or signs a live session). The reads
// above resolve identity; these create and credential it: account allocation,
// name + password set, member lookup, deletion, plus a live session signer.
// The display-name POLICY is not here: it is pure, shared with the local player
// identity, and lives in names.zig.

/// ResolvedUser is the identity subset login.zig reads: id + name + member flag
/// (admin/agent flags aren't needed by the login flows).
pub const ResolvedUser = struct { id: []const u8, name: []const u8, member: bool };

/// currentUser resolves the full identity a request acts as.
/// Zero value (id == "") when there's no identity.
pub fn currentUser(io: Io, alloc: Alloc, req: *std.http.Server.Request) !ResolvedUser {
    const id = try currentUserID(io, alloc, req);
    if (id.len == 0) return .{ .id = "", .name = "", .member = false };
    return .{
        .id = id,
        .name = try getUserName(io, alloc, id),
        .member = try userIsMember(io, alloc, id),
    };
}

/// signSessionNow signs a live member session cookie value for `id` (loads the
/// shared on-disk secret, signs at the current time). null when the secret is
/// missing. Wraps the pure signSession with the live secret + clock — the
/// issuance counterpart to verifySessionWithSecret.
pub fn signSessionNow(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    const secret = (try loadSecret(io, alloc)) orelse return null;
    return try signSession(alloc, secret, id, nowUnix(io));
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// Two halves, matching the module: the security DECISIONS are pure (no Io), and
// get frozen-vector / negative-case unit tests; the account store + quotas are
// genuinely a FILESYSTEM contract (a reservation must PERSIST, an over-cap one
// must NOT mutate), so those run against a real temp tree with a real Io — the
// disk effect IS the thing under test, not an obstacle to mock away.

test "verifySessionWithSecret accepts a genuine cookie and rejects every forgery" {
    // A frozen `base64url(id).issued.HMAC` cookie signed with a SYNTHETIC secret
    // (never the live _session_secret). Guards that the HMAC verify construction
    // stays stable — the property that lets zig read members' existing browser
    // cookies — and that no tampered/expired/malformed variant slips through.
    // No Go, no oracle.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "zig-port synthetic secret AAAAAA";
    const issued = 1700000000;
    const val = "MQ.1700000000.h2oFDiRQJ1DLR1i-otOulFYPp0GGW21Gna1nryAO59s";

    // Genuine cookie at issue time → resolves to id "1".
    try testing.expectEqualStrings("1", verifySessionWithSecret(a, secret, val, issued).?);

    // ── forgery / corruption: every one must reject ──
    // wrong secret (a different server key can't validate our cookie)
    try testing.expect(verifySessionWithSecret(a, "a totally different secret AAAA", val, issued) == null);
    // a single flipped MAC byte
    const tampered = try a.dupe(u8, val);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == 's') 't' else 's';
    try testing.expect(verifySessionWithSecret(a, secret, tampered, issued) == null);
    // wrong number of parts (2 and 4 — must be exactly 3)
    try testing.expect(verifySessionWithSecret(a, secret, "MQ.1700000000", issued) == null);
    try testing.expect(verifySessionWithSecret(a, secret, try std.fmt.allocPrint(a, "{s}.x", .{val}), issued) == null);
    // non-base64 in the MAC slot
    try testing.expect(verifySessionWithSecret(a, secret, "MQ.1700000000.!!!not-base64!!!", issued) == null);
    // expired: one second past the max-age window
    try testing.expect(verifySessionWithSecret(a, secret, val, issued + session_max_age_secs + 1) == null);

    // ── round-trip a freshly signed cookie + the exact expiry boundary ──
    const signed = try signSession(a, secret, "42", issued);
    try testing.expectEqualStrings("42", verifySessionWithSecret(a, secret, signed, issued).?);
    // exactly AT max age is still valid (the check is strictly-greater)…
    try testing.expectEqualStrings("42", verifySessionWithSecret(a, secret, signed, issued + session_max_age_secs).?);
    // …one second later is not.
    try testing.expect(verifySessionWithSecret(a, secret, signed, issued + session_max_age_secs + 1) == null);
    // Issued in the future: a small skew is a clock, more is refused (156(f)).
    try testing.expectEqualStrings("42", verifySessionWithSecret(a, secret, signed, issued - clock_skew_secs).?);
    try testing.expect(verifySessionWithSecret(a, secret, signed, issued - clock_skew_secs - 1) == null);
    const far = try signSession(a, secret, "42", std.math.maxInt(i64));
    try testing.expect(verifySessionWithSecret(a, secret, far, issued) == null);
    // A MAC of any other length, decoded as it came, ran past its 32 bytes:
    // a client's cookie a character longer was an index out of bounds.
    for ([_][]const u8{ "A", "AA", "AAAA", "AAAAAAAAAAAA" }) |more| {
        try testing.expect(verifySessionWithSecret(a, secret, try std.fmt.allocPrint(a, "{s}{s}", .{ val, more }), issued) == null);
    }
    try testing.expect(verifySessionWithSecret(a, secret, val[0 .. val.len - 1], issued) == null);
    // An issued time at the edge of i64, the MAC right for it: the age's
    // subtraction overflowed.
    const ancient = try signSession(a, secret, "42", std.math.minInt(i64));
    try testing.expect(verifySessionWithSecret(a, secret, ancient, issued) == null);
}

test "apiKeyMatches: plaintext constant-time arm and legacy sha256-hex arm" {
    // Modern plaintext key (has '-'): exact constant-time match only.
    try testing.expect(apiKeyMatches("3-deadbeefcafe", "3-deadbeefcafe"));
    try testing.expect(!apiKeyMatches("3-deadbeefcafe", "3-deadbeefcaff")); // one char off
    try testing.expect(!apiKeyMatches("3-deadbeefcafe", "3-deadbeefcaf")); // length off
    // Legacy bare hash (no '-'): matches the sha256-hex of the PRESENTED key.
    // sha256("3-rawkey") computed out-of-band (no oracle in the test).
    const legacy = "65df45737ecf94ac50d1b31b078ba3bbb9a7b7d1d4dbc538456feea5a8fc2c6c";
    try testing.expect(apiKeyMatches(legacy, "3-rawkey"));
    try testing.expect(!apiKeyMatches(legacy, "3-wrongkey"));
}

test "fs: an API key whose id is not a uid authenticates no one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved_roots = try tmpRoots(&tmp, a);
    defer saved_roots.restore();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Account 7, a member, whose api-key file holds a key whose prefix is
    // "7/." (as finding 5's admin write could leave). That prefix names
    // account 7's own folder, so the old check found a password and a
    // matching key there, and authenticated "7/." as a uid.
    const dir = try std.fs.path.join(a, &.{ users.auth_root, "7" });
    try store.makeDir(io, a, dir);
    try store.write(io, a, try std.fs.path.join(a, &.{ dir, "password" }), "x", .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ dir, "api-key" }), "7/.-abc", .{});
    try testing.expect((try checkAPIKey(io, a, "7/.-abc")) == null);
    try testing.expect((try checkAPIKey(io, a, "../auth/7-abc")) == null);

    // A real key still authenticates.
    try store.write(io, a, try std.fs.path.join(a, &.{ dir, "api-key" }), "7-abc", .{});
    try testing.expectEqualStrings("7", (try checkAPIKey(io, a, "7-abc")).?);
}

// ── issuance (account allocation, deletion, live session signing) ─────────────

test "fs: signSessionNow needs a valid secret, and the cookie it signs verifies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved_roots = try tmpRoots(&tmp, a);
    defer saved_roots.restore();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = try allocateUser(io, a, "Member");
    try setUserPassword(io, a, id, "pw");
    try Io.Dir.cwd().createDirPath(io, users.session_secret_dir);
    const spath = try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" });

    // no secret file → can't sign
    try testing.expect((try signSessionNow(io, a, id)) == null);
    // a too-short secret (< 32 bytes) is treated as absent, not half-honored
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = spath, .data = "tooshort" });
    try testing.expect((try signSessionNow(io, a, id)) == null);

    // a proper 32-byte secret → signs, and the resolver accepts what we signed
    const secret = "0123456789abcdef0123456789abcdef";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = spath, .data = secret });
    const cookie_val = (try signSessionNow(io, a, id)).?;

    // verify at the cookie's own issue instant (valid) and one past max age (not).
    var it = std.mem.splitScalar(u8, cookie_val, '.');
    _ = it.next();
    const issued = try std.fmt.parseInt(i64, it.next().?, 10);
    try testing.expectEqualStrings(id, verifySessionWithSecret(a, secret, cookie_val, issued).?);
    try testing.expect(verifySessionWithSecret(a, secret, cookie_val, issued + session_max_age_secs + 1) == null);
}
