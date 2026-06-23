//! users: identity resolution, issuance, and per-user gopher-private state.
//! The resolution half (currentUser → WHO a request acts as) came first; the
//! issuance half (account creation, password set/verify, session signing, name
//! validation) landed with the front-door login port (login.zig).
//!
//! Three roots, three concerns (config.zig sets all three at startup; nothing
//! else reaches past this module's API to touch their files):
//!   • auth_root          — the SHARED account store: name, password, api-key,
//!                          next-id. Identity + credentials + issuance.
//!   • users_root         — gopher-private per-user STATE: last-seen,
//!                          upload-bytes (the upload quota). Same file shape —
//!                          one small scalar per fact under {users_root}/{id}/.
//!   • session_secret_dir — _session_secret, the HMAC key for session cookies.
//!
//! Issuance lives here (not login.zig) because it's account-store mechanics —
//! the natural peer of the resolution reads. login.zig owns only the HTTP shell:
//! the forms, the cookies, the redirects. The bcrypt primitives are in auth.zig;
//! the session HMAC is below (signSession).
//!
//! Resolution order:
//!   1. a valid member SESSION cookie (gopher_auth, HMAC-SHA256 signed)   -> id
//!   2. a valid API key (Authorization: Bearer <id>-<secret>)            -> id
//!   3. the guest gopher_uid cookie, but ONLY if that id exists and is a
//!      NON-authorized principal (forge-check: a uid pointing at a member
//!      without a session, or an agent without a key, is ignored)        -> id
//!   else "" (no identity).
//!
//! The session HMAC + API-key compare are the security-critical crypto here;
//! they're written as secret-parameterized pure functions, so verifySessionWithSecret
//! has a frozen-vector regression test at the bottom of this file.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const auth = @import("auth.zig");
const storage = @import("storage.zig");
const http = @import("http.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

// Roots (config.zig overrides these at startup from GOPHER_CONFIG). Defaults are
// repo-relative, adjusted for the zig-server cwd.
pub var auth_root: []const u8 = "../games/lynrummy/auth-data"; // shared account store (name/password/api-key)
pub var users_root: []const u8 = "../games/lynrummy/users-data"; // gopher-private (admin/last-seen/...)
pub var session_secret_dir: []const u8 = "../games/lynrummy/data/chat"; // holds _session_secret

const claude_agent_id = "3";
const session_max_age_secs: i64 = 365 * 24 * 60 * 60;

// ── the resolver ────────────────────────────────────────────────────────────

/// currentUserID resolves the id a request acts as, or "" when there's no valid
/// identity.
pub fn currentUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) ![]const u8 {
    // 1. member session cookie (authoritative).
    if (try sessionUserID(io, alloc, req)) |id| return id;
    // 2. API key.
    if (try apiKeyUserID(io, alloc, req)) |id| return id;
    // 3. guest gopher_uid — only a non-authorized principal that exists.
    // http.cookie owns the value, so it survives a later body read (matters once
    // guests can post — e.g. name-only blog commenters).
    if (try http.cookie(req, alloc, "gopher_uid")) |uid| {
        if (allDigits(uid) and try userExists(io, alloc, uid) and !try userIsAuthorized(io, alloc, uid)) {
            return uid;
        }
    }
    return "";
}

/// sessionUserID returns the member id from a valid gopher_auth cookie whose id
/// is still a member.
fn sessionUserID(io: Io, alloc: Alloc, req: *std.http.Server.Request) !?[]const u8 {
    const val = (try http.cookie(req, alloc, "gopher_auth")) orelse return null;
    const secret = (try loadSecret(io, alloc)) orelse return null;
    const now = nowUnix(io);
    const id = verifySessionWithSecret(alloc, secret, val, now) orelse return null;
    if (!try userIsMember(io, alloc, id)) return null;
    return id;
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
    var presented: [HmacSha256.mac_length]u8 = undefined;
    (b64.Decoder.decode(&presented, p2)) catch return null; // wrong length/charset -> reject
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, computed, presented)) return null;

    // expiry: issued must parse and be within max age.
    const n = std.fmt.parseInt(i64, issued, 10) catch return null;
    if (now_unix - n > session_max_age_secs) return null;
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
fn apiKeyMatches(stored: []const u8, presented: []const u8) bool {
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
    if (id.len == 0 or !try userIsAuthorized(io, alloc, id)) return null;

    const stored_opt = readAuthFile(io, alloc, id, "api-key") catch return null;
    const stored = std.mem.trim(u8, stored_opt orelse return null, " \t\r\n");
    // `id` is a slice into `presented`, which bearerToken already owns (via
    // http.header), so it survives a later body read — no dupe needed here.
    return if (apiKeyMatches(stored, presented)) id else null;
}

// ── registry reads (account store) ───────────────────────────────────────────

/// userExists reports whether id has an account dir under auth_root.
fn userExists(io: Io, alloc: Alloc, id: []const u8) !bool {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return false;
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch return false;
    return st.kind == .directory;
}

/// userIsMember reports whether id has a password file.
fn userIsMember(io: Io, alloc: Alloc, id: []const u8) !bool {
    return authFileExists(io, alloc, id, "password");
}

/// isAgent — today exactly one agent (Claude, uid 3).
fn isAgent(id: []const u8) bool {
    return std.mem.eql(u8, id, claude_agent_id);
}

/// userIsAuthorized = member OR agent.
fn userIsAuthorized(io: Io, alloc: Alloc, id: []const u8) !bool {
    return (try userIsMember(io, alloc, id)) or isAgent(id);
}

/// AuthorizedUser is one entry of the account roster (id + display name).
pub const AuthorizedUser = struct { id: []const u8, name: []const u8 };

/// listAuthorized returns every authorized principal (member or agent) — one
/// account dir under auth_root that has a password file OR is the agent — with
/// its display name, sorted by numeric id.
/// Missing auth_root → empty.
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
/// CR/LF trimmed), or "" when absent. Allocated from
/// `alloc`.
pub fn getUserName(io: Io, alloc: Alloc, id: []const u8) ![]const u8 {
    const b = (try readAuthFile(io, alloc, id, "name")) orelse return "";
    return std.mem.trimEnd(u8, b, "\r\n");
}

/// touchUser records "now" as the user's last-seen time
/// ({users_root}/{id}/last-seen = unix seconds), best-effort (a write failure
/// isn't worth surfacing). Bumped on each Lyn Rummy move.
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
/// a runaway/abuse backstop, not a tight quota.
pub const max_upload_lifetime_bytes: i64 = 1 << 30; // 1 GiB per user, lifetime

/// upload_bytes_mu serializes the read-add-write on the lifetime upload total so
/// two concurrent uploads can't both slip past the cap.
var upload_bytes_mu: Io.Mutex = .init;

/// userUploadBytes returns the cumulative bytes a user has ever uploaded
/// ({users_root}/{id}/upload-bytes), or 0 when absent/unparseable.
pub fn userUploadBytes(io: Io, alloc: Alloc, id: []const u8) i64 {
    const path = std.fs.path.join(alloc, &.{ users_root, id, "upload-bytes" }) catch return 0;
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, b, " \t\r\n"), 10) catch 0;
}

/// reserveUploadBytes atomically adds `n` to the user's lifetime upload total if
/// that stays within max_upload_lifetime_bytes, returning true; otherwise nothing
/// changes and it returns false. Serialized via upload_bytes_mu.
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

// ── API-key management ───────

/// userHasAPIKey reports whether the principal has an API-key file.
pub fn userHasAPIKey(io: Io, alloc: Alloc, id: []const u8) bool {
    return authFileExists(io, alloc, id, "api-key") catch false;
}

/// getUserAPIKey returns the stored key for display, or null when absent OR a
/// legacy bare-hash key (no '-', not recoverable — regenerate to view).
pub fn getUserAPIKey(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    const b = (try readAuthFile(io, alloc, id, "api-key")) orelse return null;
    const key = std.mem.trim(u8, b, " \t\r\n");
    if (std.mem.indexOfScalar(u8, key, '-') == null) return null;
    return key;
}

/// setUserAPIKey generates a fresh plaintext key ("<id>-<32 hex>", 16 CSPRNG
/// bytes), stores it (mode 0o600 — treat it like a password), and returns it.
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
/// Best-effort.
pub fn clearUserAPIKey(io: Io, alloc: Alloc, id: []const u8) void {
    const path = std.fs.path.join(alloc, &.{ auth_root, id, "api-key" }) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// isMember reports whether `id` is a password member.
pub fn isMember(io: Io, alloc: Alloc, id: []const u8) bool {
    return userIsMember(io, alloc, id) catch false;
}

/// principalExists / principalAuthorized / principalIsAgent are the public
/// admin-facing wrappers over the account-store predicates,
/// swallowing errors to a plain bool.
pub fn principalExists(io: Io, alloc: Alloc, id: []const u8) bool {
    return userExists(io, alloc, id) catch false;
}
pub fn principalAuthorized(io: Io, alloc: Alloc, id: []const u8) bool {
    return userIsAuthorized(io, alloc, id) catch false;
}
pub fn principalIsAgent(id: []const u8) bool {
    return isAgent(id);
}

/// listUserIDs returns every account id (numeric dir under auth_root), sorted
/// numerically. An id exists iff it has an account dir.
pub fn listUserIDs(io: Io, alloc: Alloc) ![][]const u8 {
    var dir = Io.Dir.cwd().openDir(io, auth_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.fmt.parseInt(i64, entry.name, 10)) |_| {} else |_| continue;
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanNumericID);
    return slice;
}

fn lessThanNumericID(_: void, a: []const u8, b: []const u8) bool {
    return (std.fmt.parseInt(i64, a, 10) catch 0) < (std.fmt.parseInt(i64, b, 10) catch 0);
}

/// userLastSeen returns a user's last-activity time (Unix seconds), or null if
/// never recorded.
pub fn userLastSeen(io: Io, alloc: Alloc, id: []const u8) ?i64 {
    const path = std.fs.path.join(alloc, &.{ users_root, id, "last-seen" }) catch return null;
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, b, " \t\r\n"), 10) catch null;
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
/// Read-only: we never GENERATE a secret — we require the one already on disk.
fn loadSecret(io: Io, alloc: Alloc) !?[]const u8 {
    const path = try std.fs.path.join(alloc, &.{ session_secret_dir, "_session_secret" });
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
    if (b.len < 32) return null;
    return b;
}

// ── request parsing ──────────────────────────────────────────────────────────

/// allDigits reports whether `s` is non-empty and all ASCII digits (a well-formed uid).
fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

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

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

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
// name + password set, member lookup, deletion, name validation, plus a live
// session signer.

const max_user_len = 40; // max display-name length

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
        .member = userIsMember(io, alloc, id) catch false,
    };
}

/// allocateUser creates a new account with `name` and returns its id, bumping
/// the shared id counter (auth_root/next-id.txt) through storage.allocateID.
pub fn allocateUser(io: Io, alloc: Alloc, name: []const u8) ![]const u8 {
    const counter = try std.fs.path.join(alloc, &.{ auth_root, "next-id.txt" });
    const n = try storage.allocateID(io, alloc, counter);
    const id = try std.fmt.allocPrint(alloc, "{d}", .{n});
    try setUserName(io, alloc, id, name);
    return id;
}

/// setUserName writes a user's display name ({auth_root}/{id}/name), creating the
/// account dir (whose existence IS the user).
pub fn setUserName(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "name" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = name });
}

/// setUserPassword bcrypt-hashes `password` and stores it (mode 0o600), making
/// the user a member. The 60-byte hash has no trailing newline, so
/// checkUserPassword's verify sees exactly 60 bytes.
pub fn setUserPassword(io: Io, alloc: Alloc, id: []const u8, password: []const u8) !void {
    var buf: [60]u8 = undefined;
    const hash = try auth.hashPassword(password, &buf, io);
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "password" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = hash, .flags = .{ .permissions = @enumFromInt(0o600) } });
}

/// checkUserPassword verifies `password` against a member's stored bcrypt hash.
/// false when the member has no password file.
pub fn checkUserPassword(io: Io, alloc: Alloc, id: []const u8, password: []const u8) bool {
    const stored = (readAuthFile(io, alloc, id, "password") catch return false) orelse return false;
    return auth.verifyPassword(std.mem.trimEnd(u8, stored, "\r\n"), password);
}

/// findMemberByName returns the id of the member currently using `name`, or null.
/// A small scan. Exact byte compare, so existing unicode-named members match
/// regardless of validateUserName's policy.
pub fn findMemberByName(io: Io, alloc: Alloc, name: []const u8) !?[]const u8 {
    for (try listUserIDs(io, alloc)) |id| {
        if ((userIsMember(io, alloc, id) catch false) and
            std.mem.eql(u8, try getUserName(io, alloc, id), name)) return id;
    }
    return null;
}

/// isNameReserved reports whether some member currently holds `name`.
pub fn isNameReserved(io: Io, alloc: Alloc, name: []const u8) bool {
    return (findMemberByName(io, alloc, name) catch null) != null;
}

/// deleteUserRecord removes a user's account dir (auth_root: name/password/
/// api-key) and gopher-private dir (users_root: admin/last-seen/upload-bytes).
/// Game/chat data is deleted separately (storage.deleteUserData). Refuses an
/// empty id so it can never target a root. Best-effort.
pub fn deleteUserRecord(io: Io, alloc: Alloc, id: []const u8) void {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return;
    if (std.fs.path.join(alloc, &.{ auth_root, id })) |p| {
        Io.Dir.cwd().deleteTree(io, p) catch {};
    } else |_| {}
    if (std.fs.path.join(alloc, &.{ users_root, id })) |p| {
        Io.Dir.cwd().deleteTree(io, p) catch {};
    } else |_| {}
}

/// signSessionNow signs a live member session cookie value for `id` (loads the
/// shared on-disk secret, signs at the current time). null when the secret is
/// missing. Wraps the pure signSession with the live secret + clock — the
/// issuance counterpart to verifySessionWithSecret.
pub fn signSessionNow(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    const secret = (try loadSecret(io, alloc)) orelse return null;
    return try signSession(alloc, secret, id, nowUnix(io));
}

// ── name validation ────────────────────────────────────────
//
// UNICODE NOTE: classifying letters/digits by full Unicode tables would need data
// zig std doesn't expose, so the policy here is: ASCII letters/digits are
// letters/digits, the space and apostrophe are allowed, and ANY non-ASCII
// codepoint (byte >= 0x80) is treated as a letter. This is deliberately
// permissive — it accepts some exotic symbols a stricter check would reject — but
// it never locks out a legitimate name, and every real account name on the site
// is ASCII anyway. Length is byte-based.

const NameResult = struct { name: []const u8, err: []const u8 };

fn allowedNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ' ' or c == '\'' or c >= 0x80;
}

fn isNameAlnumByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// validateUserName cleans and checks a login-supplied name: trims, collapses
/// internal whitespace runs to one space, requires at least one letter/digit,
/// rejects any other punctuation. Returns {name, ""} on success or {"", message}
/// describing the fix.
pub fn validateUserName(alloc: Alloc, raw: []const u8) !NameResult {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .name = "", .err = "Please enter a name." };
    if (trimmed.len > max_user_len) return .{ .name = "", .err = "That name is too long (40 characters max)." };

    var b: std.ArrayList(u8) = .empty;
    var last_space = false;
    var has_alnum = false;
    for (trimmed) |c| {
        if (!allowedNameByte(c)) {
            return .{ .name = "", .err = "Names can use only letters, numbers, spaces, and apostrophes." };
        }
        if (c == ' ') {
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
            if (isNameAlnumByte(c)) has_alnum = true;
        }
        try b.append(alloc, c);
    }
    const out = std.mem.trimEnd(u8, b.items, " ");
    if (!has_alnum) return .{ .name = "", .err = "Please enter a name with at least one letter or number." };
    return .{ .name = out, .err = "" };
}

/// sanitizeUser scrubs a name into a clean attribute value: keeps allowed bytes,
/// collapses whitespace runs, caps length, "" if nothing usable remains. Lenient
/// (strips rather than rejects) — login re-checks with validateUserName.
pub fn sanitizeUser(alloc: Alloc, raw: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var last_space = false;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        if (c == ' ') {
            if (!last_space and b.items.len > 0) {
                try b.append(alloc, ' ');
                last_space = true;
            }
        } else if (allowedNameByte(c)) {
            try b.append(alloc, c);
            last_space = false;
        }
        if (b.items.len >= max_user_len) break;
    }
    return std.mem.trimEnd(u8, b.items, " ");
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// Two halves, matching the module: the security DECISIONS are pure (no Io), and
// get frozen-vector / negative-case unit tests; the account store + quotas are
// genuinely a FILESYSTEM contract (a reservation must PERSIST, an over-cap one
// must NOT mutate), so those run against a real temp tree with a real Io — the
// disk effect IS the thing under test, not an obstacle to mock away.

const testing = std.testing;

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

test "validateUserName collapses whitespace, requires alnum, rejects punctuation/overlength" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // happy: trims, collapses internal whitespace runs to one space
    try testing.expectEqualStrings("Steve Howell", (try validateUserName(a, "  Steve   Howell  ")).name);
    // apostrophe + space allowed; non-ASCII bytes treated as letters (permissive)
    try testing.expectEqualStrings("O'Brien", (try validateUserName(a, "O'Brien")).name);
    try testing.expectEqualStrings("José", (try validateUserName(a, "José")).name);

    // ── rejections: name is empty, err is set ──
    const cases = [_][]const u8{
        "   ", //                whitespace only
        "a<b", //                angle bracket (HTML-injection shaped)
        "x;y", //                semicolon
        "path/name", //          slash
        "'' ''", //              punctuation but no letter/digit
        "a" ** 41, //            41 bytes, over the 40 cap
    };
    for (cases) |raw| {
        const r = try validateUserName(a, raw);
        try testing.expectEqualStrings("", r.name);
        try testing.expect(r.err.len != 0);
    }
}

test "sanitizeUser strips disallowed bytes, collapses whitespace, caps length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // lenient: strips rather than rejects, and collapses the gap left behind
    try testing.expectEqualStrings("ab", try sanitizeUser(a, "a<b>"));
    try testing.expectEqualStrings("a b", try sanitizeUser(a, "  a < b  "));
    // nothing usable → empty
    try testing.expectEqualStrings("", try sanitizeUser(a, "<<>>"));
    // capped to max_user_len bytes
    try testing.expectEqual(@as(usize, max_user_len), (try sanitizeUser(a, "a" ** 80)).len);
}

/// tmpRoots points the three module roots at a fresh temp tree so the fs-backed
/// tests write real files without touching the live data dir.
fn tmpRoots(tmp: *testing.TmpDir, a: Alloc) !void {
    // tmpDir() makes .zig-cache/tmp/<sub_path> via Io.Dir.cwd(); users.zig's file
    // ops use that same cwd, so a relative base reaches the same tree.
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    auth_root = try std.fs.path.join(a, &.{ base, "auth" });
    users_root = try std.fs.path.join(a, &.{ base, "users" });
    session_secret_dir = try std.fs.path.join(a, &.{ base, "secret" });
}

test "fs: password set then verify; wrong and missing both reject" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try setUserName(io, a, "100", "Tester");
    try testing.expect(!isMember(io, a, "100")); // a name, but no password yet
    try setUserPassword(io, a, "100", "hunter2");
    try testing.expect(isMember(io, a, "100"));
    try testing.expect(checkUserPassword(io, a, "100", "hunter2"));
    try testing.expect(!checkUserPassword(io, a, "100", "wrong")); // wrong password
    try testing.expect(!checkUserPassword(io, a, "999", "anything")); // no such member
}

test "fs: upload quota reserves under the cap, refuses over it without mutating" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = "200";
    const cap = max_upload_lifetime_bytes;
    try testing.expectEqual(@as(i64, 0), userUploadBytes(io, a, id));

    // reserve almost the whole allowance
    try testing.expect(reserveUploadBytes(io, a, id, cap - 10));
    try testing.expectEqual(cap - 10, userUploadBytes(io, a, id));

    // a reservation that would exceed the cap is refused AND leaves the total put
    try testing.expect(!reserveUploadBytes(io, a, id, 20));
    try testing.expectEqual(cap - 10, userUploadBytes(io, a, id));

    // exactly to the cap is allowed; one byte beyond is not
    try testing.expect(reserveUploadBytes(io, a, id, 10));
    try testing.expectEqual(cap, userUploadBytes(io, a, id));
    try testing.expect(!reserveUploadBytes(io, a, id, 1));
    try testing.expectEqual(cap, userUploadBytes(io, a, id));
}

test "fs: only members reserve a name; findMemberByName resolves it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // a freshly allocated account (name only, no password) is NOT yet a member,
    // so its name is NOT reserved — a half-registered guest can't squat a name.
    const id = try allocateUser(io, a, "Alice");
    try testing.expect(!isNameReserved(io, a, "Alice"));
    try testing.expect((try findMemberByName(io, a, "Alice")) == null);

    // becoming a member (password set) reserves the name and makes it resolvable
    try setUserPassword(io, a, id, "pw");
    try testing.expect(isNameReserved(io, a, "Alice"));
    try testing.expectEqualStrings(id, (try findMemberByName(io, a, "Alice")).?);
    try testing.expect(!isNameReserved(io, a, "Bob")); // an unrelated name is free
}

test "fs: api key issue, read back, clear; legacy bare-hash is held but not displayable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = "300";
    try setUserName(io, a, id, "Agent"); // create the account dir
    try testing.expect(!userHasAPIKey(io, a, id));

    const key = try setUserAPIKey(io, a, id);
    try testing.expect(std.mem.startsWith(u8, key, "300-"));
    try testing.expect(userHasAPIKey(io, a, id));
    try testing.expectEqualStrings(key, (try getUserAPIKey(io, a, id)).?); // round-trips for display
    try testing.expect(apiKeyMatches(key, key)); // and authenticates against itself

    clearUserAPIKey(io, a, id);
    try testing.expect(!userHasAPIKey(io, a, id));
    try testing.expect((try getUserAPIKey(io, a, id)) == null);

    // a legacy bare-hash key (no '-') is honored for auth but never echoed back
    const path = try std.fs.path.join(a, &.{ auth_root, id, "api-key" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "abc123def" });
    try testing.expect(userHasAPIKey(io, a, id));
    try testing.expect((try getUserAPIKey(io, a, id)) == null);
}

// ── issuance (account allocation, deletion, live session signing) ─────────────

test "fs: allocateUser hands out distinct increasing ids and persists the name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id1 = try allocateUser(io, a, "First");
    const id2 = try allocateUser(io, a, "Second");

    // distinct, numeric, strictly increasing (the shared counter bumps)
    const n1 = try std.fmt.parseInt(i64, id1, 10);
    const n2 = try std.fmt.parseInt(i64, id2, 10);
    try testing.expect(n2 > n1);
    // each name was written and reads back against its own id
    try testing.expectEqualStrings("First", try getUserName(io, a, id1));
    try testing.expectEqualStrings("Second", try getUserName(io, a, id2));
    // a freshly allocated account exists but is not yet a member (no password)
    try testing.expect(principalExists(io, a, id1));
    try testing.expect(!isMember(io, a, id1));
}

test "fs: deleteUserRecord refuses an empty id, removes one principal, spares others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const keep = try allocateUser(io, a, "Keeper");
    try setUserPassword(io, a, keep, "pw");
    const gone = try allocateUser(io, a, "Goner");
    try setUserPassword(io, a, gone, "pw");
    try testing.expect(reserveUploadBytes(io, a, gone, 100)); // give it users_root state too

    // The safety guard: an empty/blank id must be a no-op — joined onto a root it
    // would otherwise deleteTree the whole account store. Both principals survive.
    deleteUserRecord(io, a, "");
    deleteUserRecord(io, a, "   ");
    try testing.expect(principalExists(io, a, keep));
    try testing.expect(principalExists(io, a, gone));

    // Deleting the goner removes BOTH its account dir (auth_root) and its private
    // dir (users_root); the upload total is gone with it.
    deleteUserRecord(io, a, gone);
    try testing.expect(!principalExists(io, a, gone));
    try testing.expectEqual(@as(i64, 0), userUploadBytes(io, a, gone));
    // …and the unrelated principal is untouched.
    try testing.expect(principalExists(io, a, keep));
    try testing.expect(isMember(io, a, keep));
}

test "fs: signSessionNow needs a valid secret, and the cookie it signs verifies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmpRoots(&tmp, a);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = try allocateUser(io, a, "Member");
    try setUserPassword(io, a, id, "pw");
    try Io.Dir.cwd().createDirPath(io, session_secret_dir);
    const spath = try std.fs.path.join(a, &.{ session_secret_dir, "_session_secret" });

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
