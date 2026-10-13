//! users: identity resolution, issuance, and per-user gopher-private state.
//! The resolution half (currentUser → WHO a request acts as) came first; the
//! issuance half (account creation, password set/verify, session signing, name
//! validation) landed with the front-door login port (login.zig).
//!
//! Three roots, three concerns (roots.point sets all three at startup; nothing
//! else reaches past this module's API to touch their files):
//!   • auth_root          — the SHARED account store: name, password, api-key,
//!                          next-id. Identity + credentials + issuance.
//!   • users_root         — gopher-private per-user STATE:
//!                          upload-bytes (the upload quota). Same file shape —
//!                          one small scalar per fact under {users_root}/{id}/.
//!   • session_secret_dir — _session_secret, the HMAC key for session cookies.
//!
//! Issuance lives here (not login.zig) because it's account-store mechanics —
//! the natural peer of the resolution reads. login.zig owns only the HTTP shell:
//! the forms, the cookies, the redirects. The bcrypt primitives are in auth.zig;
//! the session HMAC, the resolver below, API keys and bearer parsing are in
//! users_session.zig (split out by metal-vmm QUEUE 174), re-exported here.
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
//! has a frozen-vector regression test beside it in users_session.zig.

const users_session = @import("users_session.zig");
const apiKeyMatches = users_session.apiKeyMatches;
pub const clock_skew_secs = users_session.clock_skew_secs;
pub const currentUserID = users_session.currentUserID;
pub const session_cookie = users_session.session_cookie;
pub const session_cookie_legacy = users_session.session_cookie_legacy;
pub const sessionToMove = users_session.sessionToMove;
pub const verifySessionWithSecret = users_session.verifySessionWithSecret;
pub const signSession = users_session.signSession;
pub const sessionSecret = users_session.sessionSecret;
pub const sessionUser = users_session.sessionUser;
pub const previousSecret = users_session.previousSecret;
pub const rotateSecret = users_session.rotateSecret;
pub const ResolvedUser = users_session.ResolvedUser;
pub const currentUser = users_session.currentUser;
pub const signSessionNow = users_session.signSessionNow;

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

// Roots (roots.point overrides these at startup, from the host's roots). Defaults are
// repo-relative, adjusted for the zig-server cwd.
pub var auth_root: []const u8 = "../games/lynrummy/auth-data"; // shared account store (name/password/api-key)

pub var users_root: []const u8 = "../games/lynrummy/users-data"; // gopher-private (upload-bytes)

pub var session_secret_dir: []const u8 = "../games/lynrummy/data/chat"; // holds _session_secret

const claude_agent_id = "3";

/// userExists reports whether id has an account dir under auth_root.
pub fn userExists(io: Io, alloc: Alloc, id: []const u8) !bool {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return false;
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    const st = (try store.statOrNull(io, alloc, dir)) orelse return false;
    return st.kind == .directory;
}

/// userIsMember reports whether id has a password file.
pub fn userIsMember(io: Io, alloc: Alloc, id: []const u8) !bool {
    return authFileExists(io, alloc, id, "password");
}

/// isAgent — today exactly one agent (Claude, uid 3).
fn isAgent(id: []const u8) bool {
    return std.mem.eql(u8, id, claude_agent_id);
}

/// userIsAuthorized = member OR agent.
pub fn userIsAuthorized(io: Io, alloc: Alloc, id: []const u8) !bool {
    return (try userIsMember(io, alloc, id)) or isAgent(id);
}

/// AuthorizedUser is one entry of the account roster (id + display name).
pub const AuthorizedUser = struct { id: []const u8, name: []const u8 };

/// listAuthorized returns every authorized principal (member or agent) — one
/// account dir under auth_root that has a password file OR is the agent — with
/// its display name, sorted by numeric id.
/// Missing auth_root → empty.
pub fn listAuthorized(io: Io, alloc: Alloc) ![]AuthorizedUser {
    const entries = try store.list(io, alloc, auth_root);

    var out: std.ArrayList(AuthorizedUser) = .empty;
    for (entries) |entry| {
        if (entry.kind != .directory) continue;
        // numeric id only (the account dirs); skips next-id.txt etc.
        if (!allDigits(entry.name)) continue; // canonical only (156(i)): a 007 or +7 folder is no account
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
/// CR/LF trimmed), or "" when there is none. Allocated from `alloc`.
///
/// **A MEMBER WITH NO NAME FILE READS "", ON PURPOSE** (metal-vmm QUEUE
/// 156(i), a decision named): an account is made name first, so one with a
/// password and no name is a release cut short, which removes the name
/// before the password (134(e), 138(f)), and that member must still log in
/// by cookie to release again. What must not take "" as a name refuses it:
/// retire's plan refuses a nameless account (the box's A2), and
/// `onlyMemberNamed` never matches "".
pub fn getUserName(io: Io, alloc: Alloc, id: []const u8) ![]const u8 {
    const b = (try readAuthFile(io, alloc, id, "name")) orelse return "";
    return std.mem.trimEnd(u8, b, "\r\n");
}

/// max_upload_lifetime_bytes caps the cumulative bytes one user may ever upload —
/// a runaway/abuse backstop, not a tight quota.
pub const max_upload_lifetime_bytes: i64 = 1 << 30; // 1 GiB per user, lifetime

/// userUploadBytes returns the cumulative bytes a user has ever uploaded
/// ({users_root}/{id}/upload-bytes), 0 when there is no such file. A file
/// that cannot be read, or does not hold a number, is an error: counting it
/// as 0 would give the user their whole allowance again.
pub fn userUploadBytes(io: Io, alloc: Alloc, id: []const u8) !i64 {
    const path = try std.fs.path.join(alloc, &.{ users_root, id, "upload-bytes" });
    const b = store.read(io, alloc, path, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    return std.fmt.parseInt(i64, std.mem.trim(u8, b, " \t\r\n"), 10);
}

/// reserveUploadBytes atomically adds `n` to the user's lifetime upload total if
/// that stays within max_upload_lifetime_bytes, returning true; otherwise nothing
/// changes and it returns false. No lock: one handler runs at a time (the
/// host's turn, HOST.md), so the read, the check and the write are one step.
/// A total that cannot be read or written is an error, and the upload is
/// refused with it: neither may let an upload past the cap uncounted.
pub fn reserveUploadBytes(io: Io, alloc: Alloc, id: []const u8, n: i64) !bool {
    if (!allDigits(id)) return false;
    const total = (try userUploadBytes(io, alloc, id)) + n;
    if (total > max_upload_lifetime_bytes) return false;
    const dir = try std.fs.path.join(alloc, &.{ users_root, id });
    try store.makeDir(io, alloc, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "upload-bytes" });
    const body = try std.fmt.allocPrint(alloc, "{d}", .{total});
    try store.write(io, alloc, path, body, .{});
    return true;
}

// ── API-key management ───────

/// userHasAPIKey reports whether the principal has an API-key file.
pub fn userHasAPIKey(io: Io, alloc: Alloc, id: []const u8) bool {
    // absent-ok: display only: a key that cannot be looked at shows as none, and Generate replaces it as Regenerate would.
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
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, "api-key" });
    try store.write(io, alloc, path, key, .{ .private = true });
    return key;
}

/// clearUserAPIKey revokes the principal's key (deletes the file; absent is OK).
///
/// **A REVOKE THAT FAILED IS NOT DONE** (metal-vmm QUEUE 129): it was
/// best-effort, `catch {}`, and both callers then said "revoked" while the
/// key went on authenticating. The error goes to the caller, which answers
/// it as the failure it is.
pub fn clearUserAPIKey(io: Io, alloc: Alloc, id: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, "api-key" });
    try store.remove(io, alloc, path);
}

/// isMember reports whether `id` is a password member.
///
/// **AN ERROR IS NOT "NO"** (metal-vmm QUEUE 108), here or in the wrappers
/// below: a password file that cannot be looked at is not a missing one, and
/// answered "no" it freed a member's name for a stranger's account
/// (findMemberByName). The caller says what "could not tell" means there.
pub fn isMember(io: Io, alloc: Alloc, id: []const u8) !bool {
    return userIsMember(io, alloc, id);
}

/// principalExists / principalAuthorized / principalIsAgent are the public
/// admin-facing wrappers over the account-store predicates; an error is the
/// caller's.
pub fn principalExists(io: Io, alloc: Alloc, id: []const u8) !bool {
    return userExists(io, alloc, id);
}

pub fn principalAuthorized(io: Io, alloc: Alloc, id: []const u8) !bool {
    return userIsAuthorized(io, alloc, id);
}

pub fn principalIsAgent(id: []const u8) bool {
    return isAgent(id);
}

/// listUserIDs returns every account id (numeric dir under auth_root), sorted
/// numerically. An id exists iff it has an account dir.
pub fn listUserIDs(io: Io, alloc: Alloc) ![][]const u8 {
    const entries = try store.list(io, alloc, auth_root);

    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        if (entry.kind != .directory) continue;
        if (!allDigits(entry.name)) continue; // canonical only (156(i)): a 007 or +7 folder is no account
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanNumericID);
    return slice;
}

fn lessThanNumericID(_: void, a: []const u8, b: []const u8) bool {
    return (std.fmt.parseInt(i64, a, 10) catch 0) < (std.fmt.parseInt(i64, b, 10) catch 0);
}

fn authFileExists(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, name });
    return try store.has(io, alloc, path);
}

/// readAuthFile reads {auth_root}/{id}/{name}, or null if absent.
pub fn readAuthFile(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, name });
    return store.readOrNull(io, alloc, path, .unlimited);
}

/// allDigits reports whether `s` is non-empty and all ASCII digits (a well-formed uid).
/// Whether `id` has the shape of an account id: what allocateUser makes,
/// digits. For callers outside this file that take an id from a request.
pub fn validUid(id: []const u8) bool {
    return allDigits(id);
}

/// **CANONICAL, AS A COUNTER WRITES ONE** (metal-vmm QUEUE 156(i)): digits,
/// the first not zero (counters start at 1), so `007` and `7` are never two
/// spellings of one account, nor `007` a folder of its own.
pub fn allDigits(s: []const u8) bool {
    if (s.len == 0 or s[0] == '0') return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

pub fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// allocateUser creates a new account with `name` and returns its id, bumping
/// the account-id counter (auth_root/next-id.txt).
pub fn allocateUser(io: Io, alloc: Alloc, name: []const u8) ![]const u8 {
    const counter_path = try std.fs.path.join(alloc, &.{ auth_root, "next-id.txt" });
    const n = try counter.next(io, alloc, counter_path);
    const id = try std.fmt.allocPrint(alloc, "{d}", .{n});
    try setUserName(io, alloc, id, name);
    return id;
}

/// setUserName writes a user's display name ({auth_root}/{id}/name), creating the
/// account dir (whose existence IS the user).
pub fn setUserName(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, "name" });
    try store.replace(io, alloc, path, name, .{});
}

/// setUserPassword bcrypt-hashes `password` and stores it (mode 0o600), making
/// the user a member. The 60-byte hash has no trailing newline, so
/// checkUserPassword's verify sees exactly 60 bytes.
pub fn setUserPassword(io: Io, alloc: Alloc, id: []const u8, password: []const u8) !void {
    var buf: [60]u8 = undefined;
    const hash = try auth.hashPassword(password, &buf, io);
    const path = try std.fs.path.join(alloc, &.{ auth_root, id, "password" });
    try store.write(io, alloc, path, hash, .{ .private = true });
}

/// checkUserPassword verifies `password` against a member's stored bcrypt hash.
/// false when the member has no password file. A password that cannot be read,
/// or a hash that is no hash, admits no one and is an error (a 500), never a
/// wrong password counted toward the lockout (metal-vmm QUEUE 172).
pub fn checkUserPassword(io: Io, alloc: Alloc, id: []const u8, password: []const u8) !bool {
    const stored = (try readAuthFile(io, alloc, id, "password")) orelse return false;
    return auth.verifyPassword(std.mem.trimEnd(u8, stored, "\r\n"), password);
}

/// The one member named `name`, or null when none is or more than one is
/// (108's sign-up race): for naming an author, where a guess between two
/// would be worse than nobody. The name first: most accounts are not it, and
/// membership costs a look at the password.
pub fn onlyMemberNamed(io: Io, alloc: Alloc, name: []const u8) !?[]const u8 {
    if (name.len == 0) return null; // "" is no name: a nameless member is no match
    var found: ?[]const u8 = null;
    for (try listUserIDs(io, alloc)) |id| {
        if (!std.mem.eql(u8, try getUserName(io, alloc, id), name) or !(try userIsMember(io, alloc, id))) continue;
        if (found != null) return null;
        found = id;
    }
    return found;
}

/// findMemberByName returns the id of the member currently using `name`, or null.
/// A small scan. Exact byte compare, so existing unicode-named members match
/// regardless of validateUserName's policy.
pub fn findMemberByName(io: Io, alloc: Alloc, name: []const u8) !?[]const u8 {
    if (name.len == 0) return null; // "" is no name: a nameless member is no match
    for (try listUserIDs(io, alloc)) |id| {
        if ((try userIsMember(io, alloc, id)) and
            std.mem.eql(u8, try getUserName(io, alloc, id), name)) return id;
    }
    return null;
}

/// deleteUserRecord removes a user's account dir (auth_root: name/password/
/// api-key) and gopher-private dir (users_root: admin/upload-bytes).
/// Game/chat data is deleted separately (storage.deleteUserData). Refuses an
/// empty id so it can never target a root.
///
/// **A REMOVAL THAT FAILED IS NOT DONE** (metal-vmm QUEUE 129): it was
/// best-effort, and a refused removal of auth_root left the released account
/// logging in. The error goes to the caller.
///
/// **AUTHORITY GOES LAST** (metal-vmm QUEUE 134(e)), as the retire's does:
/// the private state (users_root) first, then the account (auth_root). A
/// failure before the account goes leaves one that still logs in, to be
/// released again; the other order answered 500 for an account already
/// gone, which nobody could log in to retry, its folder kept.
pub fn deleteUserRecord(io: Io, alloc: Alloc, id: []const u8) !void {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return;
    try store.removeTree(io, alloc, try std.fs.path.join(alloc, &.{ users_root, id }));
    try removeAccount(io, alloc, id);
}

/// removeAccount removes a user's account dir ({auth_root}/{id}), **ITS
/// PASSWORD LAST** (metal-vmm QUEUE 138(f)): std's deleteTree removes a
/// folder's files in the order the disk lists them, so a refused removal
/// after the password's left an account nobody could log in to release
/// again, its leftovers kept. Here every other file goes first, then the
/// password, then the empty folder: a failure before the password leaves
/// an account that still logs in, whatever order the disk keeps.
pub fn removeAccount(io: Io, alloc: Alloc, id: []const u8) !void {
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return;
    const dir = try std.fs.path.join(alloc, &.{ auth_root, id });
    for (try store.list(io, alloc, dir)) |entry| {
        if (std.mem.eql(u8, entry.name, "password")) continue;
        const path = try std.fs.path.join(alloc, &.{ dir, entry.name });
        if (entry.kind == .directory) try store.removeTree(io, alloc, path) else try store.remove(io, alloc, path);
    }
    try store.remove(io, alloc, try std.fs.path.join(alloc, &.{ dir, "password" }));
    try store.removeTree(io, alloc, dir);
}

const testing = std.testing;

const roots = @import("roots.zig");

/// tmpRoots points every root at a fresh temp tree so the fs-backed tests
/// write real files without touching the live data dir, and answers the roots
/// as they stood, to `defer` back (metal-vmm QUEUE 157(c)): it set three and
/// never put them back.
pub fn tmpRoots(tmp: *testing.TmpDir, a: Alloc) !roots.Saved {
    // tmpDir() makes .zig-cache/tmp/<sub_path> via Io.Dir.cwd(); users.zig's file
    // ops use that same cwd, so a relative base reaches the same tree.
    return roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
}

test "fs: password set then verify; wrong and missing both reject" {
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

    try setUserName(io, a, "100", "Tester");
    try testing.expect(!try isMember(io, a, "100")); // a name, but no password yet
    try setUserPassword(io, a, "100", "hunter2");
    try testing.expect(try isMember(io, a, "100"));
    try testing.expect(try checkUserPassword(io, a, "100", "hunter2"));
    try testing.expect(!try checkUserPassword(io, a, "100", "wrong")); // wrong password
    try testing.expect(!try checkUserPassword(io, a, "999", "anything")); // no such member
}

test "fs: a password that cannot be read, or a stored hash that is no hash, is an error, never a wrong password (metal-vmm QUEUE 172: one counted toward the lockout)" {
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

    try setUserName(io, a, "100", "Tester");
    // Its password file a folder: there, and unreadable.
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ auth_root, "100", "password" }));
    try testing.expect(std.meta.isError(checkUserPassword(io, a, "100", "hunter2")));
    // A hash torn or overwritten: no bcrypt string.
    try setUserName(io, a, "101", "Other");
    try store.write(io, a, try std.fs.path.join(a, &.{ auth_root, "101", "password" }), "$2b$12$" ++ "!" ** 53, .{ .private = true });
    try testing.expect(std.meta.isError(checkUserPassword(io, a, "101", "hunter2")));
}

test "fs: upload quota reserves under the cap, refuses over it without mutating" {
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

    const id = "200";
    const cap = max_upload_lifetime_bytes;
    try testing.expectEqual(@as(i64, 0), try userUploadBytes(io, a, id));

    // reserve almost the whole allowance
    try testing.expect(try reserveUploadBytes(io, a, id, cap - 10));
    try testing.expectEqual(cap - 10, try userUploadBytes(io, a, id));

    // a reservation that would exceed the cap is refused AND leaves the total put
    try testing.expect(!(try reserveUploadBytes(io, a, id, 20)));
    try testing.expectEqual(cap - 10, try userUploadBytes(io, a, id));

    // exactly to the cap is allowed; one byte beyond is not
    try testing.expect(try reserveUploadBytes(io, a, id, 10));
    try testing.expectEqual(cap, try userUploadBytes(io, a, id));
    try testing.expect(!(try reserveUploadBytes(io, a, id, 1)));
    try testing.expectEqual(cap, try userUploadBytes(io, a, id));
}

test "fs: an upload total that cannot be read is an error, never a fresh allowance" {
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

    // A folder where the total should be: a read that fails, not one that
    // finds nothing.
    try store.makeDir(io, a, try std.fs.path.join(a, &.{ users_root, "201", "upload-bytes" }));
    try testing.expect(std.meta.isError(userUploadBytes(io, a, "201")));
    try testing.expect(std.meta.isError(reserveUploadBytes(io, a, "201", 1)));
    // A total that is not a number is not 0 either.
    try store.makeDir(io, a, try std.fs.path.join(a, &.{ users_root, "202" }));
    try store.write(io, a, try std.fs.path.join(a, &.{ users_root, "202", "upload-bytes" }), "lots", .{});
    try testing.expect(std.meta.isError(userUploadBytes(io, a, "202")));
}

test "fs: only members reserve a name; findMemberByName resolves it" {
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

    // a freshly allocated account (name only, no password) is NOT yet a member,
    // so its name is NOT reserved — a half-registered guest can't squat a name.
    const id = try allocateUser(io, a, "Alice");
    try testing.expect((try findMemberByName(io, a, "Alice")) == null);

    // becoming a member (password set) reserves the name and makes it resolvable
    try setUserPassword(io, a, id, "pw");
    try testing.expectEqualStrings(id, (try findMemberByName(io, a, "Alice")).?);
    try testing.expect((try findMemberByName(io, a, "Bob")) == null); // an unrelated name is free
}

test "fs: api key issue, read back, clear; legacy bare-hash is held but not displayable" {
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

    const id = "300";
    try setUserName(io, a, id, "Agent"); // create the account dir
    try testing.expect(!userHasAPIKey(io, a, id));

    const key = try setUserAPIKey(io, a, id);
    try testing.expect(std.mem.startsWith(u8, key, "300-"));
    try testing.expect(userHasAPIKey(io, a, id));
    try testing.expectEqualStrings(key, (try getUserAPIKey(io, a, id)).?); // round-trips for display
    try testing.expect(apiKeyMatches(key, key)); // and authenticates against itself

    try clearUserAPIKey(io, a, id);
    try testing.expect(!userHasAPIKey(io, a, id));
    try clearUserAPIKey(io, a, id); // absent is revoked already
    try testing.expect((try getUserAPIKey(io, a, id)) == null);

    // a legacy bare-hash key (no '-') is honored for auth but never echoed back
    const path = try std.fs.path.join(a, &.{ auth_root, id, "api-key" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "abc123def" });
    try testing.expect(userHasAPIKey(io, a, id));
    try testing.expect((try getUserAPIKey(io, a, id)) == null);
}

test "fs: allocateUser hands out distinct increasing ids and persists the name" {
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
    try testing.expect(try principalExists(io, a, id1));
    try testing.expect(!try isMember(io, a, id1));
}

test "fs: reserveUploadBytes writes only under a well-formed uid" {
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

    try testing.expect(try reserveUploadBytes(io, a, "7", 100));

    for ([_][]const u8{ "", "   ", "r", "y", "7x", "p3", "../7", "7/.." }) |bad| {
        try testing.expect(!(try reserveUploadBytes(io, a, bad, 100)));
    }
    // Nothing but the well-formed uid's directory was made.
    var dir = try Io.Dir.cwd().openDir(io, users_root, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var entries: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expectEqualStrings("7", e.name);
        entries += 1;
    }
    try testing.expectEqual(@as(usize, 1), entries);
}

test "fs: deleteUserRecord refuses an empty id, removes one principal, spares others" {
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

    const keep = try allocateUser(io, a, "Keeper");
    try setUserPassword(io, a, keep, "pw");
    const gone = try allocateUser(io, a, "Goner");
    try setUserPassword(io, a, gone, "pw");
    try testing.expect(try reserveUploadBytes(io, a, gone, 100)); // give it users_root state too

    // The safety guard: an empty/blank id must be a no-op — joined onto a root it
    // would otherwise deleteTree the whole account store. Both principals survive.
    try deleteUserRecord(io, a, "");
    try deleteUserRecord(io, a, "   ");
    try testing.expect(try principalExists(io, a, keep));
    try testing.expect(try principalExists(io, a, gone));

    // Deleting the goner removes BOTH its account dir (auth_root) and its private
    // dir (users_root); the upload total is gone with it.
    try deleteUserRecord(io, a, gone);
    try testing.expect(!try principalExists(io, a, gone));
    try deleteUserRecord(io, a, gone); // gone already: done
    try testing.expectEqual(@as(i64, 0), try userUploadBytes(io, a, gone));
    // …and the unrelated principal is untouched.
    try testing.expect(try principalExists(io, a, keep));
    try testing.expect(try isMember(io, a, keep));
}

test "fs: a member whose password cannot be looked at is an error, never a free name (metal-vmm QUEUE 108)" {
    // findMemberByName read a stat error on the password as "not a member",
    // so "Create account" with that member's name, while the read failed,
    // made a second account of the same name.
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

    const id = try allocateUser(io, a, "Alice");
    try setUserPassword(io, a, id, "pw");
    // The password, there and unreadable: a link to itself loops.
    const pw = try std.fs.path.join(a, &.{ auth_root, id, "password" });
    try store.remove(io, a, pw);
    try std.Io.Dir.cwd().symLink(io, "password", pw, .{});
    try testing.expect(std.meta.isError(findMemberByName(io, a, "Alice")));
}

test "a member with no name file reads as nobody, and no name lookup finds them (metal-vmm QUEUE 156(i))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    try setUserPassword(io, a, "4", "pw");
    try testing.expectEqualStrings("", try getUserName(io, a, "4"));
    try testing.expectEqual(@as(?[]const u8, null), try onlyMemberNamed(io, a, ""));
    try testing.expectEqual(@as(?[]const u8, null), try findMemberByName(io, a, ""));
}

test "an account id is canonical: digits, the first not zero (metal-vmm QUEUE 156(i))" {
    for ([_][]const u8{ "1", "7", "10", "123" }) |ok| try testing.expect(validUid(ok));
    for ([_][]const u8{ "", "0", "007", "+7", "-7", " 7", "7 ", "7a" }) |bad| try testing.expect(!validUid(bad));
}
