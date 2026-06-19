//! users: read-only identity resolution — the port of Go's
//! users.CurrentUser(r).ID (server/users/{current,session,api_key,name,users,
//! agent}.go). Resolves WHO a request acts as, reading the SHARED account store
//! Go writes; it never issues cookies or creates users (login stays in Go/Chat).
//!
//! Resolution order mirrors CurrentUser exactly:
//!   1. a valid member SESSION cookie (gopher_auth, HMAC-SHA256 signed)   -> id
//!   2. a valid API key (Authorization: Bearer <id>-<secret>)            -> id
//!   3. the guest gopher_uid cookie, but ONLY if that id exists and is a
//!      NON-authorized principal (forge-check: a uid pointing at a member
//!      without a session, or an agent without a key, is ignored)        -> id
//!   else "" (no identity).
//!
//! The session HMAC + API-key compare are the crypto worth cross-validating
//! against Go (see the gold harness); they live as secret-parameterized pure
//! functions so the harness can drive them with a synthetic secret.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

// Roots, mirroring Go's package vars (config.zig overrides these at startup from
// GOPHER_CONFIG). Defaults match Go's repo-relative defaults, adjusted for the
// zig-server cwd.
pub var auth_root: []const u8 = "../games/lynrummy/auth-data"; // shared account store (name/password/api-key)
pub var users_root: []const u8 = "../games/lynrummy/users-data"; // gopher-private (admin/last-seen/...)
pub var session_secret_dir: []const u8 = "../games/lynrummy/data/chat"; // holds _session_secret

const claude_agent_id = "3";
const session_max_age_secs: i64 = 365 * 24 * 60 * 60;

// ── the resolver ────────────────────────────────────────────────────────────

/// currentUserID resolves the id a request acts as, or "" when there's no valid
/// identity. Mirrors users.CurrentUser(r).ID.
pub fn currentUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) ![]const u8 {
    // 1. member session cookie (authoritative).
    if (try sessionUserID(io, alloc, req)) |id| return id;
    // 2. API key.
    if (try apiKeyUserID(io, alloc, req)) |id| return id;
    // 3. guest gopher_uid — only a non-authorized principal that exists.
    const uid = currentUID(req);
    if (uid.len != 0 and try userExists(io, alloc, uid) and !try userIsAuthorized(io, alloc, uid)) {
        return uid;
    }
    return "";
}

/// sessionUserID returns the member id from a valid gopher_auth cookie whose id
/// is still a member. Mirrors SessionUser.
fn sessionUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    const val = cookie(req, "gopher_auth") orelse return null;
    const secret = (try loadSecret(io, alloc)) orelse return null;
    const now = nowUnix(io);
    const id = verifySessionWithSecret(alloc, secret, val, now) orelse return null;
    if (!try userIsMember(io, alloc, id)) return null;
    return id;
}

/// apiKeyUserID resolves the principal id from an Authorization: Bearer key.
/// Mirrors apiKeyUser -> CheckAPIKey.
fn apiKeyUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    const key = bearerToken(req) orelse return null;
    return checkAPIKey(io, alloc, key);
}

// ── session cookie crypto (cross-validated against Go) ───────────────────────

/// sessionMAC writes HMAC-SHA256(secret, id + "\n" + issued) into out. Mirrors
/// Go's sessionMAC (before its base64 step).
fn sessionMAC(secret: []const u8, id: []const u8, issued: []const u8, out: *[HmacSha256.mac_length]u8) void {
    var ctx = HmacSha256.init(secret);
    ctx.update(id);
    ctx.update("\n");
    ctx.update(issued);
    ctx.final(out);
}

/// verifySessionWithSecret validates a `base64url(id).issued.base64url(mac)`
/// cookie against `secret` at time `now_unix` (Unix seconds), returning the id
/// or null. Mirrors Go's verifySession. Fails closed on any malformation.
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
    var presented: [HmacSha256.mac_length]u8 = undefined;
    (b64.Decoder.decode(&presented, p2)) catch return null; // wrong length/charset -> reject
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, computed, presented)) return null;

    // expiry: issued must parse and be within max age.
    const n = std.fmt.parseInt(i64, issued, 10) catch return null;
    if (now_unix - n > session_max_age_secs) return null;
    return id;
}

/// signSession produces a cookie value for `id` issued at `issued_unix`, signed
/// with `secret`. Mirrors Go's signSession. Used by the gold harness (the
/// production server never issues sessions — that stays in Go/Chat).
pub fn signSession(alloc: Alloc, secret: []const u8, id: []const u8, issued_unix: i64) ![]const u8 {
    const issued = try std.fmt.allocPrint(alloc, "{d}", .{issued_unix});
    var mac: [HmacSha256.mac_length]u8 = undefined;
    sessionMAC(secret, id, issued, &mac);
    const id_b64 = try encodeB64(alloc, id);
    const mac_b64 = try encodeB64(alloc, &mac);
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ id_b64, issued, mac_b64 });
}

// ── API key (cross-validated compare) ────────────────────────────────────────

/// checkAPIKey resolves the principal id a presented key belongs to, or null.
/// Mirrors Go's CheckAPIKey: id is the prefix before '-'; the principal must be
/// authorized; the stored key compares constant-time (plaintext) or via sha256
/// (legacy bare-hash keys).
fn checkAPIKey(io: Io, alloc: Alloc, presented: []const u8) !?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, presented, '-') orelse return null;
    const id = presented[0..dash];
    if (id.len == 0 or !try userIsAuthorized(io, alloc, id)) return null;

    const stored_opt = readAuthFile(io, alloc, id, "api-key") catch return null;
    const stored = std.mem.trim(u8, stored_opt orelse return null, " \t\r\n");

    const ok = if (std.mem.indexOfScalar(u8, stored, '-') != null)
        ctEql(stored, presented)
    else blk: {
        var sum: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(presented, &sum, .{});
        const hex = std.fmt.bytesToHex(sum, .lower);
        break :blk ctEql(stored, &hex);
    };
    return if (ok) id else null;
}

// ── registry reads (account store) ───────────────────────────────────────────

/// userExists reports whether id has an account dir under auth_root. Mirrors
/// UserExists (existence of the account dir IS the user).
fn userExists(io: Io, alloc: Alloc, id: []const u8) !bool {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return false;
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch return false;
    return st.kind == .directory;
}

/// userIsMember reports whether id has a password file. Mirrors UserIsMember.
fn userIsMember(io: Io, alloc: Alloc, id: []const u8) !bool {
    return authFileExists(io, alloc, id, "password");
}

/// isAgent — today exactly one agent (Claude, uid 3). Mirrors IsAgent.
fn isAgent(id: []const u8) bool {
    return std.mem.eql(u8, id, claude_agent_id);
}

/// userIsAuthorized = member OR agent. Mirrors UserIsAuthorized.
fn userIsAuthorized(io: Io, alloc: Alloc, id: []const u8) !bool {
    return (try userIsMember(io, alloc, id)) or isAgent(id);
}

/// AuthorizedUser is one entry of the account roster (id + display name).
pub const AuthorizedUser = struct { id: []const u8, name: []const u8 };

/// listAuthorized returns every authorized principal (member or agent) — one
/// account dir under auth_root that has a password file OR is the agent — with
/// its display name, sorted by numeric id. Mirrors the subset of
/// users.ListAuthorized the chat sidebar needs. Missing auth_root → empty.
pub fn listAuthorized(io: Io, alloc: Alloc) ![]AuthorizedUser {
    var dir = Io.Dir.cwd().openDir(io, auth_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList(AuthorizedUser) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // numeric id only (the account dirs); skips next-id.txt etc.
        if (std.fmt.parseInt(i64, entry.name, 10)) |_| {} else |_| continue;
        const id = try alloc.dupe(u8, entry.name);
        if (!try userIsAuthorized(io, alloc, id)) continue;
        const name = try getUserName(io, alloc, id);
        try out.append(alloc, .{ .id = id, .name = name });
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(AuthorizedUser, slice, {}, lessThanByNumericID);
    return slice;
}

fn lessThanByNumericID(_: void, a: AuthorizedUser, b: AuthorizedUser) bool {
    return (std.fmt.parseInt(i64, a.id, 10) catch 0) < (std.fmt.parseInt(i64, b.id, 10) catch 0);
}

/// getUserName returns a user's display name ({auth_root}/{id}/name, trailing
/// CR/LF trimmed), or "" when absent. Mirrors users.GetUserName. Allocated from
/// `alloc`.
pub fn getUserName(io: Io, alloc: Alloc, id: []const u8) ![]const u8 {
    const b = (try readAuthFile(io, alloc, id, "name")) orelse return "";
    return std.mem.trimEnd(u8, b, "\r\n");
}

/// touchUser records "now" as the user's last-seen time
/// ({users_root}/{id}/last-seen = unix seconds), best-effort like Go's TouchUser
/// (a write failure isn't worth surfacing). Bumped on each Lyn Rummy move.
pub fn touchUser(io: Io, alloc: Alloc, id: []const u8) void {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return;
    touchUserImpl(io, alloc, id) catch {};
}

fn touchUserImpl(io: Io, alloc: Alloc, id: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ users_root, id });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "last-seen" });
    const body = try std.fmt.allocPrint(alloc, "{d}", .{nowUnix(io)});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

/// max_upload_lifetime_bytes caps the cumulative bytes one user may ever upload —
/// a runaway/abuse backstop, not a tight quota. Mirrors Go's MaxUploadLifetimeBytes.
pub const max_upload_lifetime_bytes: i64 = 1 << 30; // 1 GiB per user, lifetime

/// upload_bytes_mu serializes the read-add-write on the lifetime upload total so
/// two concurrent uploads can't both slip past the cap. Mirrors Go's uploadBytesMu.
var upload_bytes_mu: Io.Mutex = .init;

/// userUploadBytes returns the cumulative bytes a user has ever uploaded
/// ({users_root}/{id}/upload-bytes), or 0 when absent/unparseable. Mirrors Go's
/// UserUploadBytes.
fn userUploadBytes(io: Io, alloc: Alloc, id: []const u8) i64 {
    const path = std.fs.path.join(alloc, &.{ users_root, id, "upload-bytes" }) catch return 0;
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, b, " \t\r\n"), 10) catch 0;
}

/// reserveUploadBytes atomically adds `n` to the user's lifetime upload total if
/// that stays within max_upload_lifetime_bytes, returning true; otherwise nothing
/// changes and it returns false. Serialized via upload_bytes_mu. Mirrors Go's
/// ReserveUploadBytes (the cap is the module const, as every Go caller passes).
pub fn reserveUploadBytes(io: Io, alloc: Alloc, id: []const u8, n: i64) bool {
    upload_bytes_mu.lockUncancelable(io);
    defer upload_bytes_mu.unlock(io);
    const total = userUploadBytes(io, alloc, id) + n;
    if (total > max_upload_lifetime_bytes) return false;
    const dir = std.fs.path.join(alloc, &.{ users_root, id }) catch return false;
    Io.Dir.cwd().createDirPath(io, dir) catch return false;
    const path = std.fs.path.join(alloc, &.{ dir, "upload-bytes" }) catch return false;
    const body = std.fmt.allocPrint(alloc, "{d}", .{total}) catch return false;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch {};
    return true;
}

// ── API-key management (port of users/api_key.go's member-facing half) ───────

/// userHasAPIKey reports whether the principal has an API-key file. Mirrors
/// UserHasAPIKey.
pub fn userHasAPIKey(io: Io, alloc: Alloc, id: []const u8) bool {
    return authFileExists(io, alloc, id, "api-key") catch false;
}

/// getUserAPIKey returns the stored key for display, or null when absent OR a
/// legacy bare-hash key (no '-', not recoverable — regenerate to view). Mirrors
/// GetUserAPIKey.
pub fn getUserAPIKey(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    const b = (try readAuthFile(io, alloc, id, "api-key")) orelse return null;
    const key = std.mem.trim(u8, b, " \t\r\n");
    if (std.mem.indexOfScalar(u8, key, '-') == null) return null;
    return key;
}

/// setUserAPIKey generates a fresh plaintext key ("<id>-<32 hex>", 16 CSPRNG
/// bytes), stores it (mode 0o600 — treat it like a password), and returns it.
/// Mirrors SetUserAPIKey.
pub fn setUserAPIKey(io: Io, alloc: Alloc, id: []const u8) ![]const u8 {
    var b: [16]u8 = undefined;
    io.random(b[0..]);
    const hex = std.fmt.bytesToHex(b, .lower); // [32]u8
    const key = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ id, &hex });
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "api-key" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = key, .flags = .{ .permissions = @enumFromInt(0o600) } });
    return key;
}

/// clearUserAPIKey revokes the principal's key (deletes the file; absent is OK).
/// Best-effort. Mirrors ClearUserAPIKey.
pub fn clearUserAPIKey(io: Io, alloc: Alloc, id: []const u8) void {
    const path = std.fs.path.join(alloc, &.{ auth_root, id, "api-key" }) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// isMember reports whether `id` is a password member (Go's NEED_PASSWORD gate
/// for the settings page — agents, who have no password, are excluded).
pub fn isMember(io: Io, alloc: Alloc, id: []const u8) bool {
    return userIsMember(io, alloc, id) catch false;
}

fn authFileExists(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, name });
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// readAuthFile reads {auth_root}/{id}/{name}, or null if absent.
fn readAuthFile(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, name });
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
}

/// loadSecret reads {session_secret_dir}/_session_secret (>= 32 bytes), or null.
/// Read-only: unlike Go we never GENERATE a secret — we share the one Go wrote.
fn loadSecret(io: Io, alloc: Alloc) !?[]const u8 {
    const path = try std.fs.path.join(alloc, &.{ session_secret_dir, "_session_secret" });
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
    if (b.len < 32) return null;
    return b;
}

// ── request parsing ──────────────────────────────────────────────────────────

/// currentUID returns the gopher_uid cookie value if it's all digits, else "".
/// Mirrors CurrentUID (the raw identity claim).
fn currentUID(req: *std.http.Server.Request) []const u8 {
    const v = cookie(req, "gopher_uid") orelse return "";
    if (v.len == 0) return "";
    for (v) |ch| {
        if (ch < '0' or ch > '9') return "";
    }
    return v;
}

/// bearerToken extracts the token from an Authorization: Bearer <token> header.
fn bearerToken(req: *std.http.Server.Request) ?[]const u8 {
    const h = header(req, "authorization") orelse return null;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, h, prefix)) return null;
    const tok = std.mem.trim(u8, h[prefix.len..], " \t");
    return if (tok.len == 0) null else tok;
}

/// cookie returns the value of cookie `name` from any Cookie header, or null.
fn cookie(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var hit = req.iterateHeaders();
    while (hit.next()) |hdr| {
        if (!std.ascii.eqlIgnoreCase(hdr.name, "cookie")) continue;
        var pairs = std.mem.splitScalar(u8, hdr.value, ';');
        while (pairs.next()) |raw| {
            const pair = std.mem.trim(u8, raw, " \t");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
    }
    return null;
}

/// header returns the first header whose name case-insensitively matches.
fn header(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var hit = req.iterateHeaders();
    while (hit.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, name)) return hdr.value;
    }
    return null;
}

// ── small helpers ────────────────────────────────────────────────────────────

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// ctEql is a constant-time slice compare (matches Go's subtle.ConstantTimeCompare:
/// unequal lengths short-circuit to false, equal lengths compare in constant time).
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
