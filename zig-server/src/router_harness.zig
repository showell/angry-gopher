//! **THESE EXIST BECAUSE OF THE SPLIT.** Routing used to be reachable only
//! through a socket, so it had no tests at all. `route` now takes a request, an
//! Io, an allocator and a bus — so a test can hand it a canned request over a
//! fixed reader and read the response out of a buffer, with no listener, no port
//! and no config. The same four arguments are what the bare-metal host supplies.

const std = @import("std");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
const streams = @import("webbox").bus;
const Bus = streams.Bus;
const Hub = streams.Hub;
const roots = @import("roots.zig");
const testing = std.testing;
const router = @import("router.zig");

/// serve runs one raw HTTP request through `route` and answers the raw response.
/// This is the whole harness: `std.http.Server` over a reader that is a string
/// and a writer that is a buffer.
pub fn serve(alloc: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    return serveFrom(alloc, io, raw, null);
}

/// serve, from a connection whose address the host knows to be `peer`.
pub fn serveFrom(alloc: std.mem.Allocator, io: Io, raw: []const u8, peer: ?[]const u8) ![]const u8 {
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(alloc);
    var server = std.http.Server.init(&reader, &out.writer);

    var req = try server.receiveHead();
    req.head.keep_alive = false;

    var hub = Hub.init(io, alloc);
    var b = Bus.of(&hub);
    b.peer = peer;
    if (try router.route(&req, io, alloc, &b)) |k| streams.drop(&hub, k);
    try out.writer.flush();
    return out.written();
}

pub fn get(alloc: std.mem.Allocator, io: Io, target: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{target});
    return serve(alloc, io, raw);
}

pub fn status(response: []const u8) []const u8 {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
    const sp = std.mem.indexOfScalar(u8, response[0..line_end], ' ') orelse return "";
    return response[sp + 1 .. line_end];
}

/// The value of response header `name`, or null.
pub fn responseHeader(response: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

pub fn responseBody(response: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[head_end + 4 ..];
}

/// A site in a temporary folder, every root pointed at it, with a session
/// secret; `deinit` puts the roots back for the rest of the test binary.
pub const UidSite = struct {
    tmp: testing.TmpDir,
    saved: roots.Saved,
    base: []const u8,
    forgot: @import("game_limits.zig").Forgot,

    pub const storage = @import("storage.zig");
    const chat_store = @import("chat_store.zig");
    pub const disk = @import("webbox").store;
    pub const game_limits = @import("game_limits.zig");
    pub const secret = "a session secret of thirty-two bytes or more, for router tests";

    pub fn init(a: std.mem.Allocator, io: Io) !UidSite {
        var s: UidSite = .{ .tmp = testing.tmpDir(.{}), .saved = undefined, .base = undefined, .forgot = undefined };
        s.base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &s.tmp.sub_path });
        s.saved = try roots.pointForTest(a, s.base);
        errdefer s.saved.restore();
        try disk.write(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" }), secret, .{});
        s.forgot = UidSite.game_limits.forgetForTest(); // what it kept was measured under other roots
        return s;
    }

    pub fn deinit(s: *UidSite) void {
        s.forgot.end();
        s.saved.restore();
        s.tmp.cleanup();
    }

    /// GET `target` with `cookies` as the Cookie header.
    pub fn ask(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8) ![]const u8 {
        return serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ target, cookies }));
    }

    /// Closes the window for unsigned cookies: a time in the past.
    pub fn closeWindow(a: std.mem.Allocator, io: Io) !void {
        try disk.replace(io, a, try std.fs.path.join(a, &.{ player.player_root, "unsigned-window" }), "1\n", .{});
    }

    pub fn isSigned(a: std.mem.Allocator, io: Io, id: []const u8) bool {
        const p = std.fs.path.join(a, &.{ player.player_root, id, "signed" }) catch return false;
        // absent-ok: a test's look at its own temporary folder; a failure there fails the test's expect.
        return disk.has(io, a, p) catch false;
    }
};

/// The value of the response's __Host-gopher_uid Set-Cookie, or null.
pub fn setUid(response: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, response, "set-cookie: __Host-gopher_uid=") orelse return null;
    const rest = response[at + "set-cookie: __Host-gopher_uid=".len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, ';') orelse rest.len];
}

pub fn playingAs(response: []const u8, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "Currently playing as <strong>{s}</strong>", .{name}) catch return false;
    return std.mem.indexOf(u8, response, want) != null;
}

pub fn nowSecs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// A signed gopher_uid cookie for `id`, as /play would have set: signed an
/// hour ago, so it is inside its lifetime whenever the tests run.
pub fn signedUid(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    return std.fmt.allocPrint(a, "__Host-gopher_uid={s}", .{try uid_cookie.sign(a, UidSite.secret, id, nowSecs(threaded.io()) - 3600)});
}

pub fn postAs(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    return serve(a, io, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body }));
}

/// An admin session for UidSite: uid 1, with a password.
pub fn adminSession(a: std.mem.Allocator, io: Io) ![]const u8 {
    try users.setUserName(io, a, "1", "Steve");
    try users.setUserPassword(io, a, "1", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "1", now)});
}

/// A member's session for UidSite.
pub fn memberSession(a: std.mem.Allocator, io: Io, uid: []const u8, name: []const u8) ![]const u8 {
    try users.setUserName(io, a, uid, name);
    try users.setUserPassword(io, a, uid, "pw");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, UidSite.secret, uid, now)});
}

/// A transcript as the store lays it out: one message a body, numbered from 1.
pub fn writeTranscript(a: std.mem.Allocator, io: Io, dir: []const u8, sid: []const u8, bodies: []const []const u8) !void {
    const chat_store = @import("chat_store.zig");
    var t: std.ArrayList(u8) = .empty;
    for (bodies, 1..) |body, n| {
        if (n > 1) try t.appendSlice(a, chat_store.sep);
        try t.print(a, "MSG_{s}_{d}\nfrom: Someone\ndate: 2026-10-10T00:{d:0>2}:00Z\n\n{s}", .{ sid, n, n % 60, body });
    }
    const path = try std.fs.path.join(a, &.{ chat_store.chat_root, dir, "sessions", try std.fmt.allocPrint(a, "{s}.md", .{sid}) });
    try UidSite.disk.write(io, a, path, t.items, .{});
}

pub fn postForm(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    return serve(a, io, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body }));
}

/// **ANSWERS FROZEN** (metal-vmm QUEUE 263d): where a test held the Roc's
/// answers to the old Zig's, byte for byte (chat_actions_twin.zig, retired),
/// the Roc's answers are pinned as one SHA-256 of them all, each
/// length-prefixed, taken the day the two agreed, so the hash is the old
/// Zig's answers too, its script hashes read as `freezable` reads them. A
/// change of one byte fails; to see where, run the test at the commit before
/// 263d, which held it to the Zig.
pub const Frozen = struct {
    h: std.crypto.hash.sha2.Sha256 = .init(.{}),
    n: usize = 0,

    pub fn add(f: *Frozen, bytes: []const u8) void {
        f.n += 1;
        freezable(&f.h, bytes);
    }

    pub fn check(f: *Frozen, comptime what: []const u8, want: []const u8, answers: usize) !void {
        var d: [32]u8 = undefined;
        f.h.final(&d);
        const got = std.fmt.bytesToHex(d, .lower);
        if (f.n == answers and std.mem.eql(u8, &got, want)) return;
        std.debug.print(what ++ ": {d} answers hash to {s}; frozen: {d}, {s}\n", .{ f.n, &got, answers, want });
        return error.TestUnexpectedResult;
    }
};

/// **A FROZEN ANSWER NEVER HOLDS A SCRIPT'S HASH**: `bytes`, length-prefixed,
/// into `h`, every `?h=` and the hex after it (a page's src for a script,
/// `/chat/<name>?h=<hash of its bytes>`, webbox http.hashedSrc) as `?h=*`.
/// A page names each script by its bytes, so without this an edit to any
/// script moves every freeze that holds a page, though no answer changed.
/// The same reason `scriptsRun` (chat_actions_twin_test.zig) names a
/// script's bytes and hash by its name. The one home for both freezes'
/// reading (`Frozen` and chat_actions_twin_test's `freezeRun`).
pub fn freezable(h: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "?h=")) |at| {
        h.update(bytes[i .. at + 3]);
        h.update("*");
        i = at + 3;
        while (i < bytes.len and std.ascii.isHex(bytes[i])) i += 1;
    }
    h.update(bytes[i..]);
}
