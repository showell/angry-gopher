//! router: WHAT THIS SITE SERVES. One function — `route` — from a request to a
//! response, over a path-prefix table with one arm per surface.
//!
//! It is separate from server.zig because that file is HOW THIS PROCESS STARTS:
//! a page allocator, a thread pool, an environment, a config file, a socket. A
//! route table needs none of those. It needs a request, an Io, an allocator and
//! the pub/sub bus, and every one of those can come from somewhere other than
//! Linux — which is the point. gopher-metal boots the same application on a
//! machine with no operating system, and until this split it had to skip the
//! routing entirely and call one page's handler by hand, because the table was
//! welded to the thing that owned the socket.
//!
//! The rule that keeps it that way: **nothing in this file may reach for the
//! host.** No std.process, no listener, no allocator policy, no clock it did not
//! receive. If a handler needs one of those it takes it as a parameter, the way
//! every handler here takes `io`.
//!
//! A second thing falls out: a route table you can call is a route table you can
//! test, without a socket.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const driving = @import("driving.zig");
const delivery = @import("delivery.zig");
const chess = @import("chess.zig");
const puzzles = @import("puzzles.zig");
const game = @import("game.zig");
const chat = @import("chat.zig");
const settings = @import("settings.zig");
const tutorial = @import("tutorial.zig");
const admin = @import("admin.zig");
const admin_lynrummy = @import("admin_lynrummy.zig");
const home = @import("home.zig");
const gallery = @import("gallery.zig");
const downloads = @import("downloads.zig");
const resume_page = @import("resume_page.zig");
const safari_download = @import("safari_download.zig");
const login = @import("login.zig");
const player = @import("player.zig");
const brand = @import("brand.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
// ── THE HOST CONTRACT ────────────────────────────────────────────────────────
//
// What any host must do before it calls `route`, and everything it needs to do
// it with. A kernel that boots this table has no other contact with the
// application, so all of it is exported from here:
//
//   1. mem_meter.init(base)     name the process-lifetime allocator. There is no
//                               default: an allocation before this panics.
//   2. roots.point(base, r)     point every store at the data. Without it the
//                               stores read repo-relative defaults, which is
//                               right for a dev checkout and nothing else.
//   3. a Hub, built over base   one per process: the registry chat publishes
//                               through. Each request gets a Bus handle on it.
//   4. store.backfillAll(...)   once, before the first request: give every chat
//                               session on disk its last-message record, which
//                               /chat/recent reads instead of every transcript
//                               in full. A host that skips it answers the same
//                               but slower — and leaves different files behind,
//                               which is a difference the judge next door sees.
//   5. after route() returns,   if the request's Bus holds a kept stream, serve
//      serve what it kept       it: `streams.serveKept` blocks until the client
//                               goes away; `streams.nextFrame` hands over the
//                               next event, for a host with one loop. Either
//                               way `streams.drop` ends it.
//   6. optionally,              hand /admin/host the host's own facts: start
//      host_status.provide(r)   time, disks, memory. Skipped, that page shows
//                               the application's half only.
//   7. game_limits.free_space   how much of the data volume is free. Without
//      = fn                     it there is no floor under the game store
//                               (game_limits.zig): set it.
//
// server.zig does these for Linux, via config.zig. gopher-metal's kernel does
// them with its own heap and paths on its own volume.

/// The streaming seam: Hub, Bus (part of `route`'s signature), Kept, and the
/// two ways to serve a kept stream.
pub const streams = @import("bus.zig");
pub const Bus = streams.Bus;
pub const Hub = streams.Hub;
pub const mem_meter = @import("mem_meter.zig");
pub const roots = @import("roots.zig");
/// Optional: `host_status.provide(report)` hands /admin/host the host's own
/// facts (start time, disks, memory). A host that skips it gets the
/// application's half of that page only.
pub const host_status = @import("host_status.zig");
/// Chat's on-disk store, for the one thing a host does with it directly:
/// `store.backfillAll` at startup.
pub const store = @import("chat_store.zig");
/// The game store's bounds (gopher-metal QUEUE item 52): a host sets
/// `game_limits.free_space` so that game writes stop before the volume fills.
pub const game_limits = @import("game_limits.zig");

/// **BACK TO THE SAME PAGE, ON THIS SITE ONLY.** The re-sign's redirect named
/// the request target as it came, so `GET //evil.example/x` answered
/// `location: //evil.example/x`, which a browser reads as another host, and
/// the absolute form `GET http://evil.example/` named one outright
/// (gopher-metal REVIEW-signed-uid-and-limits.md, finding 2). A target that is
/// not a plain local path is sent to `/` instead.
fn localTarget(target: []const u8) []const u8 {
    if (target.len == 0 or target[0] != '/') return "/";
    if (target.len > 1 and (target[1] == '/' or target[1] == '\\')) return "/";
    return target;
}

/// route picks the handler by path prefix, passing the remainder (the path with
/// the prefix stripped, e.g. "/app.js" or "/sessions/3/..."). The table below IS
/// the site: every surface appears exactly once, and the comment on each arm
/// says who may reach it.
pub fn route(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *Bus) !void {
    // **AN UNSIGNED gopher_uid IS RE-IDENTIFIED ONCE** (uid_cookie.zig): its
    // first GET inside the window comes back to the same page with the
    // signed cookie set, and the unsigned spelling is refused from then on.
    if (try uid_cookie.reissue(io, alloc, req)) |set_cookie| {
        return req.respond("", .{ .status = .see_other, .extra_headers = &.{
            .{ .name = "location", .value = localTarget(try http.target(req, alloc)) },
            .{ .name = "set-cookie", .value = set_cookie },
        } });
    }
    const path = stripQuery(try http.target(req, alloc));
    // Who is asking, for the bounds on what one address may make and write
    // (game_limits.zig). Read with the head, which a body read invalidates.
    const client = try game_limits.clientAddress(alloc, req, bus.peer);

    if (matchPrefix(path, "/driving")) |sub| {
        try driving.handle(req, sub);
    } else if (matchPrefix(path, "/delivery")) |sub| {
        try delivery.handle(req, sub);
    } else if (matchPrefix(path, "/chess")) |sub| {
        // Public + ungated like /driving: little chess toys (Knight's Tour,
        // Eight Queens) + /chess/code, the sources-as-exhibit page. The viewer
        // is resolved for the index's top-bar chip, never gated.
        try chess.handle(req, alloc, (try viewer(io, alloc, req)).name, sub);
    } else if (matchPrefix(path, "/puzzles")) |sub| {
        try puzzles.handle(req, io, alloc, sub, client);
    } else if (matchPrefix(path, "/game")) |sub| {
        try game.handle(req, io, alloc, sub, client);
    } else if (matchPrefix(path, "/chat")) |sub| {
        try chat.handle(req, io, alloc, bus, sub);
    } else if (matchPrefix(path, "/channel")) |sub| {
        try chat.handleChannel(req, io, alloc, bus, sub);
    } else if (matchPrefix(path, "/settings")) |sub| {
        try settings.handle(req, io, alloc, bus, sub);
    } else if (matchPrefix(path, "/tutorial")) |sub| {
        // Public + ungated: the Lyn Rummy beginner tutorial — its audience
        // is people who haven't made an account yet.
        try tutorial.handle(req, sub);
    } else if (matchPrefix(path, "/gallery")) |sub| {
        // Hidden-for-now: unlinked but public + ungated. Serves the stylized app
        // images (free-standing content read from gallery/) for the home page.
        try gallery.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/downloads")) |sub| {
        // Public + ungated: downloadable artifacts (the native Linux Safari
        // executable) read from downloads/, rsync'd on deploy — see downloads.zig.
        try downloads.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/admin/lynrummy")) |sub| {
        // The GAME roster. Checked before /admin, which would otherwise swallow
        // it: matchPrefix takes the first arm that matches.
        try admin_lynrummy.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/admin")) |sub| {
        try admin.handle(req, io, alloc, sub);
    } else if (std.mem.eql(u8, path, "/play") or std.mem.eql(u8, path, "/play/")) {
        // The LOCAL identity: a name, no password, for /game and /puzzles. It
        // reads its own small store and never touches the chat account store —
        // see player.zig.
        try player.handle(req, io, alloc, client);
    } else if (matchPrefix(path, "/login")) |sub| {
        try login.handle(req, io, alloc, bus, sub);
    } else if (std.mem.eql(u8, path, "/logout")) {
        try login.handleLogout(req, io, alloc);
    } else if (matchPrefix(path, "/images")) |sub| {
        try brand.handle(req, sub);
    } else if (std.mem.eql(u8, path, "/safari_download") or std.mem.eql(u8, path, "/safari_download/")) {
        // Public, read-only. The "Install locally" landing page for the Safari
        // screensaver (server-owned markdown → download links) — see safari_download.zig.
        try safari_download.handle(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/steve-resume")) {
        // Public, read-only. A single server-owned markdown page (pages/steve-resume.md)
        // rendered through the trusted markdown pipeline — no viewer resolution, no gate.
        try resume_page.handle(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/steve-resume.pdf")) {
        // The pre-generated static PDF of the same page (ops/build_resume_pdf).
        try resume_page.handlePdf(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/version")) {
        try home.handleVersion(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/debug/mem")) {
        // The leak smoke detector: live bytes/allocs on the base allocator. The
        // stress harness hammers an endpoint and watches this climb (leak) or
        // plateau (legit cache). Public + ungated on purpose — it leaks no data,
        // only aggregate counts.
        try home.handleDebugMem(req, alloc);
    } else if (std.mem.eql(u8, path, "/")) {
        // The site root: the launch pad. TOTALLY_PUBLIC, so resolve the viewer
        // for the top bar but never gate. The explicit-"/" check plus the
        // notFound fallthrough below means any non-"/" path 404s.
        const v = try viewer(io, alloc, req);
        try home.handleHome(req, io, alloc, v.name, v.is_admin, path);
    } else {
        try http.notFound(req);
    }
}

/// Viewer is what a PUBLIC page needs for its top bar: a name to print, and
/// whether this is the host. EITHER identity can supply the name — a chat member
/// through the account store, a Lyn Rummy player through the local one — and a
/// page that only prints a chip should not have to know which it got. Anonymous
/// is the empty name, which those pages already render as a Log in link.
const Viewer = struct { name: []const u8, is_admin: bool };

fn viewer(io: Io, alloc: std.mem.Allocator, req: *std.http.Server.Request) !Viewer {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len != 0) return .{
        .name = try users.getUserName(io, alloc, uid),
        // The host is uid "1" (see admin.zig), so this does too.
        .is_admin = std.mem.eql(u8, uid, "1"),
    };
    return .{ .name = (try player.current(io, alloc, req)).name, .is_admin = false };
}

/// matchPrefix returns the path tail after `prefix` when `path` is exactly
/// `prefix` or `prefix` followed by '/'. Returns null otherwise — so "/drivingX"
/// does NOT match "/driving". The tail keeps its leading '/' (or is empty).
fn matchPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const tail = path[prefix.len..];
    if (tail.len == 0 or tail[0] == '/') return tail;
    return null;
}

/// stripQuery returns the target up to the first '?' (e.g. /driving/blitter.js?v=…).
fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// **THESE EXIST BECAUSE OF THE SPLIT.** Routing used to be reachable only
// through a socket, so it had no tests at all. `route` now takes a request, an
// Io, an allocator and a bus — so a test can hand it a canned request over a
// fixed reader and read the response out of a buffer, with no listener, no port
// and no config. The same four arguments are what the bare-metal host supplies.

const testing = std.testing;

/// serve runs one raw HTTP request through `route` and answers the raw response.
/// This is the whole harness: `std.http.Server` over a reader that is a string
/// and a writer that is a buffer.
fn serve(alloc: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    return serveFrom(alloc, io, raw, null);
}

/// serve, from a connection whose address the host knows to be `peer`.
fn serveFrom(alloc: std.mem.Allocator, io: Io, raw: []const u8, peer: ?[]const u8) ![]const u8 {
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(alloc);
    var server = std.http.Server.init(&reader, &out.writer);

    var req = try server.receiveHead();
    req.head.keep_alive = false;

    var hub = Hub.init(io, alloc);
    var b = Bus.of(&hub);
    b.peer = peer;
    try route(&req, io, alloc, &b);
    if (b.kept) |k| streams.drop(&hub, k);
    try out.writer.flush();
    return out.written();
}

fn get(alloc: std.mem.Allocator, io: Io, target: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{target});
    return serve(alloc, io, raw);
}

fn status(response: []const u8) []const u8 {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
    const sp = std.mem.indexOfScalar(u8, response[0..line_end], ' ') orelse return "";
    return response[sp + 1 .. line_end];
}

test "route: the table answers, and an unknown path is a 404" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A surface with no identity and no store behind it: pure embedded bytes.
    try testing.expectEqualStrings("200 OK", status(try get(a, io, "/tutorial")));

    // The fallthrough. "/drivingX" must NOT reach /driving — matchPrefix wants a
    // boundary, and this is the case that rule exists for.
    try testing.expectEqualStrings("404 Not Found", status(try get(a, io, "/nope")));
    try testing.expectEqualStrings("404 Not Found", status(try get(a, io, "/drivingX")));

    // Only "/" is the index; the notFound fallthrough catches everything else.
    try testing.expectEqualStrings("200 OK", status(try get(a, io, "/")));
}

test "route: a query string never changes which arm is taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // stripQuery's whole job: the asset URLs carry a cache-busting ?v=.
    try testing.expectEqualStrings("200 OK", status(try get(a, io, "/tutorial?v=zig")));
}

test "route: the game surfaces send a nameless visitor to /play, not into the store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No cookie, so no player. The gate IS the contract — see puzzles.zig.
    const r = try get(a, io, "/puzzles");
    try testing.expectEqualStrings("303 See Other", status(r));
    try testing.expect(std.mem.indexOf(u8, r, "location: /play?next=/puzzles") != null);

    const g = try get(a, io, "/game");
    try testing.expectEqualStrings("303 See Other", status(g));
    try testing.expect(std.mem.indexOf(u8, g, "location: /play?next=/game") != null);
}

test "route: ADMIN_ONLY — both admin screens refuse an anonymous request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The gate is admin_ui.requireAdmin. With no identity it sends you to the
    // password door — never to /play, which would hand out a name and get you
    // no closer. This is the regression that must never pass.
    for ([_][]const u8{ "/admin", "/admin/lynrummy" }) |path| {
        const r = try get(a, io, path);
        try testing.expectEqualStrings("303 See Other", status(r));
        try testing.expect(std.mem.indexOf(u8, r, "location: /login/full") != null);
        try testing.expect(std.mem.indexOf(u8, r, "/play") == null);
    }

    // And a non-admin identity gets a 404 rather than a confirmation that the
    // page is there. (A bare gopher_uid is a guest: never an authorized member,
    // so it can never be uid 1.)
    const raw = "GET /admin HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid=1\r\n\r\n";
    const r = try serve(a, io, raw);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") == null);
}

// ── gopher_uid, signed (uid_cookie.zig) ──────────────────────────────────────

/// A site in a temporary folder, every root pointed at it, with a session
/// secret; `deinit` puts the roots back for the rest of the test binary.
const UidSite = struct {
    tmp: testing.TmpDir,
    saved: [8]?[]const u8,
    base: []const u8,

    const storage = @import("storage.zig");
    const chat_store = @import("chat_store.zig");
    const disk = @import("store.zig");
    const game_limits = @import("game_limits.zig");
    const secret = "a session secret of thirty-two bytes or more, for router tests";

    fn init(a: std.mem.Allocator, io: Io) !UidSite {
        var s: UidSite = .{ .tmp = testing.tmpDir(.{}), .saved = .{
            storage.data_root,       users.users_root,     player.player_root, users.session_secret_dir,
            chat_store.chat_root,    users.auth_root,      disk.data_base,    disk.auth_base,
        }, .base = undefined };
        s.base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &s.tmp.sub_path });
        try roots.point(a, .{
            .data_dir = try std.fs.path.join(a, &.{ s.base, "data" }),
            .auth_dir = try std.fs.path.join(a, &.{ s.base, "auth" }),
        });
        try disk.write(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" }), secret, .{});
        UidSite.game_limits.forgetAll(); // what it kept was measured under other roots
        return s;
    }

    fn deinit(s: *UidSite) void {
        storage.data_root = s.saved[0].?;
        users.users_root = s.saved[1].?;
        player.player_root = s.saved[2].?;
        users.session_secret_dir = s.saved[3].?;
        chat_store.chat_root = s.saved[4].?;
        users.auth_root = s.saved[5].?;
        disk.data_base = s.saved[6];
        disk.auth_base = s.saved[7];
        UidSite.game_limits.forgetAll();
        s.tmp.cleanup();
    }

    /// GET `target` with `cookies` as the Cookie header.
    fn ask(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8) ![]const u8 {
        return serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ target, cookies }));
    }

    /// Closes the window for unsigned cookies: a time in the past.
    fn closeWindow(a: std.mem.Allocator, io: Io) !void {
        try disk.replace(io, a, try std.fs.path.join(a, &.{ player.player_root, "unsigned-window" }), "1\n", .{});
    }

    fn marked(a: std.mem.Allocator, io: Io, id: []const u8) bool {
        return disk.has(io, a, std.fs.path.join(a, &.{ player.player_root, id, "signed" }) catch return false);
    }
};

/// The value of the response's gopher_uid Set-Cookie, or null.
fn setUid(response: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, response, "set-cookie: gopher_uid=") orelse return null;
    const rest = response[at + "set-cookie: gopher_uid=".len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, ';') orelse rest.len];
}

fn playingAs(response: []const u8, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "Currently playing as <strong>{s}</strong>", .{name}) catch return false;
    return std.mem.indexOf(u8, response, want) != null;
}

test "route: an unsigned gopher_uid is re-identified once, then never" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    const id = try player.allocate(io, a, "Nikhil");
    const unsigned = try std.fmt.allocPrint(a, "gopher_uid={s}", .{id});

    // The owner's first visit: a redirect to the same page that sets the
    // signed cookie, and the id marked.
    const first = try UidSite.ask(a, io, "/play?next=/game", unsigned);
    try testing.expectEqualStrings("303 See Other", status(first));
    try testing.expect(std.mem.indexOf(u8, first, "location: /play?next=/game") != null);
    const signed = setUid(first) orelse return error.NoSetCookie;
    try testing.expectEqualStrings(id, uid_cookie.verify(UidSite.secret, signed).?);
    try testing.expect(UidSite.marked(a, io, id));

    // The signed cookie is the player.
    const with_signed = try std.fmt.allocPrint(a, "gopher_uid={s}", .{signed});
    const page = try UidSite.ask(a, io, "/play", with_signed);
    try testing.expectEqualStrings("200 OK", status(page));
    try testing.expect(playingAs(page, "Nikhil"));

    // The unsigned spelling, again: no one, and no cookie handed out.
    const again = try UidSite.ask(a, io, "/play", unsigned);
    try testing.expectEqualStrings("200 OK", status(again));
    try testing.expect(!playingAs(again, "Nikhil"));
    try testing.expect(setUid(again) == null);
    const game_page = try UidSite.ask(a, io, "/game", unsigned);
    try testing.expect(std.mem.indexOf(u8, game_page, "location: /play?next=/game") != null);

    // A POST with it is never the re-identification: no redirect, no cookie.
    const other = try player.allocate(io, a, "Debbie");
    const post = try serve(a, io, try std.fmt.allocPrint(a,
        "POST /play HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid={s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n", .{other}));
    try testing.expect(setUid(post) == null); // an empty name: the form again, no player made
    try testing.expect(!playingAs(post, "Debbie")); // and the form names no one
    try testing.expect(!UidSite.marked(a, io, other));
}

test "route: a guest upgrades only with a signed cookie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    // A legacy guest: an account with a name and no password.
    try users.setUserName(io, a, "7", "Gus");
    const upgrade = "Set a password to use chat";
    const post_body = "name=Gus&password=forged&action=register&next=%2F";
    const post = try std.fmt.allocPrint(a,
        "POST /login/full HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid=7\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ post_body.len, post_body });

    // Unsigned, straight to the POST: the stranger form, and no password set.
    const forged = try serve(a, io, post);
    try testing.expect(std.mem.indexOf(u8, forged, upgrade) == null);
    try testing.expect(!users.isMember(io, a, "7"));

    // The guest's own first GET re-signs, and the signed cookie upgrades.
    const first = try UidSite.ask(a, io, "/login/full", "gopher_uid=7");
    try testing.expectEqualStrings("303 See Other", status(first));
    const signed = setUid(first) orelse return error.NoSetCookie;
    const page = try UidSite.ask(a, io, "/login/full", try std.fmt.allocPrint(a, "gopher_uid={s}", .{signed}));
    try testing.expect(std.mem.indexOf(u8, page, upgrade) != null);

    // After it, the unsigned spelling is the stranger form, POST or GET.
    try testing.expect(std.mem.indexOf(u8, try serve(a, io, post), upgrade) == null);
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/login/full", "gopher_uid=7"), upgrade) == null);
    try testing.expect(!users.isMember(io, a, "7"));
}

test "route: an unsigned gopher_uid never names a member, the agent, a stranger, or anyone once the window shuts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    // A member, with a game identity under their own number.
    try users.setUserName(io, a, "1", "Steve");
    try users.setUserPassword(io, a, "1", "hunter2");
    player.mirror(io, a, "1", "Steve");
    // The agent.
    try users.setUserName(io, a, "3", "Claude");
    player.mirror(io, a, "3", "Claude");
    for ([_][]const u8{ "gopher_uid=1", "gopher_uid=3", "gopher_uid=p99", "gopher_uid=../1" }) |c| {
        const r = try UidSite.ask(a, io, "/play", c);
        try testing.expectEqualStrings("200 OK", status(r));
        try testing.expect(setUid(r) == null);
        try testing.expect(!playingAs(r, "Steve") and !playingAs(r, "Claude"));
    }
    try testing.expect(!UidSite.marked(a, io, "1"));

    // A forged signature: the right shape, the wrong MAC.
    const forged = try uid_cookie.sign(a, "not the site's secret, though just as long", "1", 1_790_000_000);
    const f = try UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{forged}));
    try testing.expect(!playingAs(f, "Steve"));

    // The member's games follow their session.
    const session = try users.signSession(a, UidSite.secret, "1", @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s)));
    const m = try UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_auth={s}", .{session}));
    try testing.expect(playingAs(m, "Steve"));

    // A player never yet signed, once the window has shut: no one.
    const id = try player.allocate(io, a, "Nikhil");
    try UidSite.closeWindow(a, io);
    const late = try UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{id}));
    try testing.expectEqualStrings("200 OK", status(late));
    try testing.expect(setUid(late) == null);
    try testing.expect(!playingAs(late, "Nikhil"));
    try testing.expect(!UidSite.marked(a, io, id));
}

test "route: /play mints a signed gopher_uid, marked as signed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    const r = try serve(a, io,
        "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 23\r\n\r\nname=Nikhil&next=%2Fgame");
    try testing.expectEqualStrings("303 See Other", status(r));
    const v = setUid(r) orelse return error.NoSetCookie;
    const id = uid_cookie.verify(UidSite.secret, v) orelse return error.Unsigned;
    try testing.expect(UidSite.marked(a, io, id));
    // Its unsigned spelling is refused from the start.
    const bare = try UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{id}));
    try testing.expect(!playingAs(bare, "Nikhil"));
    // With no session secret, nothing is minted: no unsigned cookie instead.
    try removeSecret(a, io);
    const none = try serve(a, io,
        "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 23\r\n\r\nname=Debbie&next=%2Fgame");
    try testing.expectEqualStrings("500 Internal Server Error", status(none));
    try testing.expect(setUid(none) == null);
}

fn removeSecret(a: std.mem.Allocator, io: Io) !void {
    try UidSite.disk.remove(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" }));
}

// ── the game store's growth (gopher-metal QUEUE item 52) ─────────────────────

/// A signed gopher_uid cookie for `id`, as /play would have set.
fn signedUid(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "gopher_uid={s}", .{try uid_cookie.sign(a, UidSite.secret, id, 1_790_000_000)});
}

fn postAs(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    return serve(a, io, try std.fmt.allocPrint(a,
        "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body }));
}

test "route: /puzzles writes nothing; a session is made by its first move" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    const id = try player.allocate(io, a, "Nikhil");
    const me = try signedUid(a, id);
    const games = try std.fs.path.join(a, &.{ UidSite.storage.data_root, id });

    // Loaded three times: the same session offered, and nothing on disk.
    for (0..3) |_| {
        const page = try UidSite.ask(a, io, "/puzzles", me);
        try testing.expectEqualStrings("200 OK", status(page));
        try testing.expect(std.mem.indexOf(u8, page, "session_id: 1\\n") != null);
    }
    try testing.expect(!UidSite.disk.has(io, a, games));

    // An id never offered makes nothing.
    try testing.expectEqualStrings("404 Not Found", status(try postAs(a, io, "/puzzles/sessions/5/puzzles/0/actions", me, "1) x")));
    try testing.expect(!UidSite.disk.has(io, a, games));

    // The first move makes the session, with its meta, and lands.
    try testing.expectEqualStrings("204 No Content", status(try postAs(a, io, "/puzzles/sessions/1/puzzles/0/actions", me, "1) x")));
    const s1 = try std.fs.path.join(a, &.{ games, "puzzle", "sessions", "1" });
    const meta = try UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ s1, "meta" }), .limited(1 << 20));
    try testing.expect(std.mem.startsWith(u8, meta, "created_at: "));
    try testing.expect(std.mem.indexOf(u8, meta, "\ncatalog:\n") != null);
    // A second move, from a tab offered the same id, lands in the same one.
    try testing.expectEqualStrings("204 No Content", status(try postAs(a, io, "/puzzles/sessions/1/puzzles/0/actions", me, "2) y")));
    try testing.expectEqualStrings("1) x\n2) y\n", try UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ s1, "puzzle_0", "actions.dsl" }), .limited(64)));

    // The next load offers the next session.
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/puzzles", me), "session_id: 2\\n") != null);
}

test "route: a player's games are refused, 507, past 16 MiB or 500 sessions, and all below a quarter free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const limits = UidSite.game_limits;

    const id = try player.allocate(io, a, "Nikhil");
    const me = try signedUid(a, id);
    const games = try std.fs.path.join(a, &.{ UidSite.storage.data_root, id });

    // A game, then its folder filled to 100 bytes short of the bound.
    const made = try postAs(a, io, "/game/new-session", me, "state");
    try testing.expectEqualStrings("200 OK", status(made));
    limits.forgetAll(); // the filler below is written behind its back
    const meta_len = (try UidSite.disk.stat(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "1", "meta" }))).size;
    const counter_len = (try UidSite.disk.stat(io, a, try std.fs.path.join(a, &.{ games, "next-session-id.txt" }))).size;
    const filler = try a.alloc(u8, limits.max_bytes - meta_len - counter_len - 100);
    @memset(filler, 'x');
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ games, "filler" }), filler, .{});

    // 99 bytes and its newline: exactly to the bound. Then one byte more is refused.
    const line = "y" ** 99;
    try testing.expectEqualStrings("204 No Content", status(try postAs(a, io, "/game/sessions/1/actions", me, line)));
    const over = try postAs(a, io, "/game/sessions/1/actions", me, "z");
    try testing.expectEqualStrings("507 Insufficient Storage", status(over));
    try testing.expect(std.mem.indexOf(u8, over, "16 MiB") != null);
    try testing.expectEqualStrings("507 Insufficient Storage", status(try postAs(a, io, "/game/new-session", me, "state")));
    try testing.expectEqualStrings("507 Insufficient Storage", status(try postAs(a, io, "/puzzles/sessions/1/puzzles/0/actions", me, "1) x")));
    // Nothing of the refused writes landed.
    const actions = try UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "1", "actions.dsl" }), .limited(1 << 10));
    try testing.expectEqual(@as(usize, 100), actions.len);
    try testing.expect(!UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "2" })));
    try testing.expect(!UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ games, "puzzle" })));

    // Sessions: another player with 500 on disk may not make one more,
    // but may still play in the ones they have.
    const other = try player.allocate(io, a, "Debbie");
    const them = try signedUid(a, other);
    for (1..limits.max_sessions + 1) |n| {
        try UidSite.disk.write(io, a, try std.fmt.allocPrint(a, "{s}/{s}/puzzle/sessions/{d}/meta", .{ UidSite.storage.data_root, other, n }), "m", .{});
    }
    const refused = try postAs(a, io, "/game/new-session", them, "state");
    try testing.expectEqualStrings("507 Insufficient Storage", status(refused));
    try testing.expect(std.mem.indexOf(u8, refused, "500 game sessions") != null);
    try testing.expectEqualStrings("204 No Content", status(try postAs(a, io, "/puzzles/sessions/7/puzzles/0/actions", them, "1) x")));

    // The floor: below a quarter free, nobody's game is saved; /play still
    // names a new player (the player store is not the game store).
    limits.free_space = lowDisk;
    defer limits.free_space = null;
    const third = try player.allocate(io, a, "Gus");
    const floor = try postAs(a, io, "/game/new-session", try signedUid(a, third), "state");
    try testing.expectEqualStrings("507 Insufficient Storage", status(floor));
    try testing.expect(std.mem.indexOf(u8, floor, "low on disk") != null);
    const named = try serve(a, io,
        "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 21\r\n\r\nname=Ann&next=%2Fgame");
    try testing.expectEqualStrings("303 See Other", status(named));
}

fn lowDisk() ?@import("game_limits.zig").Space {
    return .{ .free = 1 << 30, .total = 5 << 30 };
}

test "route: an address names 5 players an hour and saves 20 MB of games, then 429" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const limits = UidSite.game_limits;
    limits.trusted_proxy = "10.0.0.1";
    defer limits.trusted_proxy = null;

    const Name = struct {
        fn post(al: std.mem.Allocator, i: Io, peer: []const u8, xff: []const u8) ![]const u8 {
            const body = "name=Ann&next=%2Fgame";
            return serveFrom(al, i, try std.fmt.allocPrint(al,
                "POST /play HTTP/1.1\r\nHost: x\r\n{s}Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ xff, body.len, body }), peer);
        }
    };

    // Straight from an address: five, then a 429 that says why.
    for (0..limits.players_per_hour) |_|
        try testing.expectEqualStrings("303 See Other", status(try Name.post(a, io, "203.0.113.7", "")));
    const sixth = try Name.post(a, io, "203.0.113.7", "");
    try testing.expectEqualStrings("429 Too Many Requests", status(sixth));
    try testing.expect(std.mem.indexOf(u8, sixth, "the last hour") != null);
    try testing.expect(setUid(sixth) == null);
    // Another address is its own.
    try testing.expectEqualStrings("303 See Other", status(try Name.post(a, io, "198.51.100.1", "")));
    // An X-Forwarded-For from anyone but the proxy is not believed: still 203.0.113.7.
    try testing.expectEqualStrings("429 Too Many Requests", status(try Name.post(a, io, "203.0.113.7", "X-Forwarded-For: 192.0.2.50\r\n")));

    // Through the proxy: the last address it forwarded for is the one counted,
    // whatever the client put before it.
    for (0..limits.players_per_hour) |_|
        try testing.expectEqualStrings("303 See Other", status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 1.2.3.4, 192.0.2.9\r\n")));
    try testing.expectEqualStrings("429 Too Many Requests", status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 5.6.7.8, 192.0.2.9\r\n")));
    try testing.expectEqualStrings("303 See Other", status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 192.0.2.9, 192.0.2.10\r\n")));

    // Game writes: 20 MB from one address an hour, across players.
    const ids = [_][]const u8{ try player.allocate(io, a, "One"), try player.allocate(io, a, "Two") };
    const big = try a.alloc(u8, 200 * 1024);
    @memset(big, 's');
    var sent: u64 = 0;
    var refused: ?[]const u8 = null;
    var n: usize = 0;
    while (refused == null) : (n += 1) {
        const r = try serveFrom(a, io, try std.fmt.allocPrint(a,
            "POST /game/new-session HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ try signedUid(a, ids[n % 2]), big.len, big }), "203.0.113.7");
        if (std.mem.eql(u8, status(r), "429 Too Many Requests")) refused = r else {
            try testing.expectEqualStrings("200 OK", status(r));
            sent += big.len;
        }
    }
    try testing.expect(std.mem.indexOf(u8, refused.?, "20 MB") != null);
    try testing.expect(sent <= limits.bytes_per_hour and sent + 2 * big.len > limits.bytes_per_hour);
    // Neither player is near their own 16 MiB: it was the address.
    try testing.expect(sent / 2 < limits.max_bytes);
    // From elsewhere, the same player still saves.
    try testing.expectEqualStrings("200 OK", status(try serveFrom(a, io, try std.fmt.allocPrint(a,
        "POST /game/new-session HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 5\r\n\r\nstate", .{try signedUid(a, ids[0])}), "198.51.100.1")));
}

// ── /admin/backup (gopher-metal REVIEW-admin-backup.md) ──────────────────────

/// An admin session for UidSite: uid 1, with a password.
fn adminSession(a: std.mem.Allocator, io: Io) ![]const u8 {
    try users.setUserName(io, a, "1", "Steve");
    try users.setUserPassword(io, a, "1", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "1", now)});
}

test "route: HEAD /admin/backup reads nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const admin_backup = @import("admin_backup.zig");
    const me = try adminSession(a, io);

    const before = admin_backup.files_archived;
    const head = try serve(a, io, try std.fmt.allocPrint(a, "HEAD /admin/backup HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expectEqualStrings("200 OK", status(head));
    try testing.expectEqual(before, admin_backup.files_archived);
    // The download (a POST with the password) does walk it: the secret and
    // the account files, at least.
    const got = try postForm(a, io, "/admin/backup", me, "password=hunter2");
    try testing.expectEqualStrings("200 OK", status(got));
    try testing.expect(admin_backup.files_archived >= before + 3);
}

fn postForm(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    return serve(a, io, try std.fmt.allocPrint(a,
        "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body }));
}

test "route: /admin/backup asks for the password again, and gives nothing without it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const admin_backup = @import("admin_backup.zig");
    const me = try adminSession(a, io);
    const before = admin_backup.files_archived;

    // The session alone: a form, not the archive.
    const page = try UidSite.ask(a, io, "/admin/backup", me);
    try testing.expectEqualStrings("200 OK", status(page));
    try testing.expect(std.mem.indexOf(u8, page, "type=\"password\"") != null);
    try testing.expect(std.mem.indexOf(u8, page, "application/x-tar") == null);
    // A wrong password, and none: refused, nothing walked.
    for ([_][]const u8{ "password=wrong", "", "pass=hunter2" }) |body| {
        const r = try postForm(a, io, "/admin/backup", me, body);
        try testing.expectEqualStrings("403 Forbidden", status(r));
        try testing.expect(std.mem.indexOf(u8, r, "application/x-tar") == null);
    }
    try testing.expectEqual(before, admin_backup.files_archived);
    // The right one: the archive, ending with its manifest.
    const tar = try postForm(a, io, "/admin/backup", me, "password=hunter2");
    try testing.expectEqualStrings("200 OK", status(tar));
    try testing.expect(std.mem.indexOf(u8, tar, "application/x-tar") != null);
    try testing.expect(std.mem.indexOf(u8, tar, admin_backup.manifest_name) != null);
    // Nobody else gets as far as the form, with the admin's password or not:
    // no identity is sent to log in, and a member who is not the admin is a 404.
    try testing.expectEqualStrings("303 See Other", status(try postForm(a, io, "/admin/backup", "gopher_uid=1", "password=hunter2")));
    try users.setUserName(io, a, "2", "apoorva");
    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const other = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});
    try testing.expectEqualStrings("404 Not Found", status(try postForm(a, io, "/admin/backup", other, "password=hunter2")));
    try testing.expectEqual(@as(usize, 0), admin_backup.files_archived - before - countFiles(tar));
}

/// How many manifest lines name a file, in an archive's text.
fn countFiles(tar: []const u8) usize {
    const at = std.mem.lastIndexOf(u8, tar, "\nend: ") orelse return 0;
    var it = std.mem.tokenizeAny(u8, tar[at + "\nend: ".len ..], " ");
    return std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
}

test "route: the re-sign's redirect stays on this site" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    const cases = [_][2][]const u8{
        .{ "//evil.example/x", "/" },
        .{ "/\\evil.example/x", "/" },
        .{ "http://evil.example/y", "/" },
        .{ "/play?next=/game", "/play?next=/game" },
    };
    for (cases) |c| {
        // A fresh legacy player each time: a re-sign happens once per id.
        const id = try player.allocate(io, a, "Nikhil");
        const r = try serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid={s}\r\n\r\n", .{ c[0], id }));
        try testing.expectEqualStrings("303 See Other", status(r));
        try testing.expect(std.mem.indexOf(u8, r, try std.fmt.allocPrint(a, "location: {s}\r\n", .{c[1]})) != null);
    }
}
