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
/// Bus is re-exported because it is part of `route`'s signature: a host has to
/// construct one to call the table, and the kernel that does has no other
/// contact with the application.
pub const Bus = @import("bus.zig").Bus;

/// route picks the handler by path prefix, passing the remainder (the path with
/// the prefix stripped, e.g. "/app.js" or "/sessions/3/..."). The table below IS
/// the site: every surface appears exactly once, and the comment on each arm
/// says who may reach it.
pub fn route(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *Bus) !void {
    const path = stripQuery(try http.target(req, alloc));

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
        try puzzles.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/game")) |sub| {
        try game.handle(req, io, alloc, sub);
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
        try player.handle(req, io, alloc);
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
        try home.handleVersion(req, alloc);
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

/// stripQuery returns the target up to the first '?' (e.g. /driving/app.js?v=…).
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
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(alloc);
    var server = std.http.Server.init(&reader, &out.writer);

    var req = try server.receiveHead();
    req.head.keep_alive = false;

    var bus = Bus.init(io, alloc);
    try route(&req, io, alloc, &bus);
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
