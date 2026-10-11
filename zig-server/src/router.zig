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
const client_address = @import("client_address.zig");
const free_space = @import("free_space.zig");
// ── THE HOST CONTRACT ────────────────────────────────────────────────────────
//
// What any host does to serve this table. A kernel that boots it has no other
// contact with the application, so all of it is exported from here. Three
// calls (Steve, 2026-10-10: one call for the setup, not a list a host follows
// by hand):
//
//   1. mem_meter.init(base)     name the process-lifetime allocator, before
//                               anything else (a host builds its own I/O and
//                               heaps on it). An allocation before it panics.
//   2. start(io, Host)          once, before the first request: everything the
//                               host supplies in one struct (where the data
//                               is, the game store's floor, the trusted proxy,
//                               /admin/host's facts), and the setup done in
//                               the one right order (host_start.zig). Answers
//                               the Hub, and what its one-time passes did.
//   3. per request: route(),    which answers the stream a handler kept, if
//      then serve what it       one did (157(a)), for the host to serve:
//      answered                 `streams.serveKept` blocks until the client
//                               goes away; `streams.nextFrame` hands over the
//                               next event, for a host with one loop. Either
//                               way `streams.drop` ends it. On an error route
//                               has dropped it already.
//
// server.zig does these for Linux, gopher-metal's kernel with its own heap and
// paths on its own volume.

/// The streaming seam: Hub, Bus (part of `route`'s signature), Kept, and the
/// two ways to serve a kept stream.
pub const streams = @import("bus.zig");
pub const Bus = streams.Bus;
pub const Hub = streams.Hub;
pub const mem_meter = @import("mem_meter.zig");
/// The setup as one call (host_start.zig): contract step 2.
pub const host_start = @import("host_start.zig");
pub const start = host_start.start;
pub const Host = host_start.Host;
/// **ONLY WHAT A HOST NEEDS IS EXPORTED**: the types `Host` is made of and a
/// host's facts are written in. The setup's modules (roots, the stores, the
/// search index, the game limits) are not, so nothing but `start` sets them.
pub const Roots = roots.Roots;
pub const Space = free_space.Space;
/// Where the game store is, for a host's `Host.floor` to read the free space
/// of (read only).
pub const dataRoot = game_limits.dataRoot;
/// /admin/host's host half (host_facts.zig): what a host's facts are made of,
/// and the two ways it writes a time; `start` hands its report over.
pub const host_facts = struct {
    pub const Fact = facts.Fact;
    pub const utc = facts.utc;
    pub const duration = facts.duration;
    const facts = @import("host_facts.zig");
};
const roots = @import("roots.zig");
/// Every bound on what a request may bring (limits.zig): a host sizes its
/// request-head buffer from `request_limits.head_bytes`.
pub const request_limits = @import("limits.zig");
/// Chat's on-disk store; `start` gives every session its last-message record.
const store = @import("chat_store.zig");
/// Search's index in memory; `start` builds it, and its Stats is what
/// `Started.search` says.
const search_index = @import("search_index.zig");
/// The game store's bounds (gopher-metal QUEUE item 52): the free space a
/// host's `Host.floor` reads (`Space`), and where the game store is
/// (`dataRoot`).
const game_limits = @import("game_limits.zig");
/// The edge's refusal counts, which /version reports: a host counts what it
/// refuses before the route table sees a request (`edge.count(.header_too_large)`
/// for a head past its read buffer), in the same counters the routes use.
pub const edge = @import("edge.zig");
/// The largest upload a plain GET reads whole; a bigger one is streamed. A host
/// with a page cache keeps files up to this by default, so what it keeps and
/// what is read whole are one line (gopher-metal's `probe/gopher.zig`).
pub const whole_read_max = @import("chat_upload.zig").whole_read_max;

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

/// **THIS APPLICATION, AS THE LIBRARY SERVES IT** (webbox's site.zig): its
/// route table is `routed`, private, so no host calls the table without the
/// serving around it. A malformed form is the client's mistake, a 400, on
/// every form (metal-vmm QUEUE 156(i)): one decoder (http.formField), where
/// chat's own took a bad escape as text and the first of two fields, while
/// players' refused the escape as a 500.
const App = struct {
    pub const routes = routed;
};
const Served = @import("site.zig").Site(App);

/// route picks the handler by path prefix, passing the remainder (the path with
/// the prefix stripped, e.g. "/app.js" or "/sessions/3/..."). The table below IS
/// the site: every surface appears exactly once, and the comment on each arm
/// says who may reach it. The serving around it (the 500 for a failure, the
/// 400 for a malformed form, the kept stream as the answer) is site.zig's.
pub const route = Served.route;

fn routed(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *Bus) !void {
    // **AN UNSIGNED gopher_uid IS RE-IDENTIFIED ONCE** (uid_cookie.zig): its
    // first GET inside the window comes back to the same page with the
    // signed cookie set, and the unsigned spelling is refused from then on.
    // Who is asking, for the bounds on what one address may make and write
    // (game_limits.zig). Read with the head, which a body read invalidates.
    const client = try client_address.resolve(alloc, req, bus.peer);
    if (try uid_cookie.reissue(io, alloc, req, client)) |re| switch (re) {
        .cookie => |set_cookie| return req.respond("", .{ .status = .see_other, .extra_headers = &.{
            .{ .name = "location", .value = localTarget(try http.target(req, alloc)) },
            .{ .name = "set-cookie", .value = set_cookie },
        } }),
        .refused => |r| return game_limits.refuse(req, r),
    };
    const path = http.pathOf(try http.target(req, alloc));

    if (http.pathUnder(path, "/driving")) |sub| {
        try driving.handle(req, alloc, sub);
    } else if (http.pathUnder(path, "/delivery")) |sub| {
        try delivery.handle(req, alloc, sub);
    } else if (http.pathUnder(path, "/chess")) |sub| {
        // Public + ungated like /driving: little chess toys (Knight's Tour,
        // Eight Queens) + /chess/code, the sources-as-exhibit page. The viewer
        // is resolved for the index's top-bar chip, never gated.
        try chess.handle(req, alloc, (try viewer(io, alloc, req)).name, sub);
    } else if (http.pathUnder(path, "/puzzles")) |sub| {
        try puzzles.handle(req, io, alloc, sub, client);
    } else if (http.pathUnder(path, "/game")) |sub| {
        try game.handle(req, io, alloc, sub, client);
    } else if (http.pathUnder(path, "/chat")) |sub| {
        try chat.handle(req, io, alloc, bus, sub);
    } else if (http.pathUnder(path, "/channel")) |sub| {
        try chat.handleChannel(req, io, alloc, bus, sub);
    } else if (http.pathUnder(path, "/settings")) |sub| {
        try settings.handle(req, io, alloc, bus, sub);
    } else if (http.pathUnder(path, "/tutorial")) |sub| {
        // Public + ungated: the Lyn Rummy beginner tutorial — its audience
        // is people who haven't made an account yet.
        try tutorial.handle(req, alloc, sub);
    } else if (http.pathUnder(path, "/gallery")) |sub| {
        // Hidden-for-now: unlinked but public + ungated. Serves the stylized app
        // images (free-standing content read from gallery/) for the home page.
        try gallery.handle(req, io, alloc, sub);
    } else if (http.pathUnder(path, "/downloads")) |sub| {
        // Public + ungated: downloadable artifacts (the native Linux Safari
        // executable) read from downloads/, rsync'd on deploy — see downloads.zig.
        try downloads.handle(req, io, alloc, sub);
    } else if (http.pathUnder(path, "/admin/lynrummy")) |sub| {
        // The GAME roster. Checked before /admin, which would otherwise swallow
        // it: http.pathUnder takes the first arm that matches.
        try admin_lynrummy.handle(req, io, alloc, sub);
    } else if (http.pathUnder(path, "/admin")) |sub| {
        try admin.handle(req, io, alloc, client, sub);
    } else if (std.mem.eql(u8, path, "/play") or std.mem.eql(u8, path, "/play/")) {
        // The LOCAL identity: a name, no password, for /game and /puzzles. It
        // reads its own small store and never touches the chat account store —
        // see player.zig.
        try player.handle(req, io, alloc, client);
    } else if (http.pathUnder(path, "/login")) |sub| {
        try login.handle(req, io, alloc, bus, sub);
    } else if (std.mem.eql(u8, path, "/logout")) {
        try login.handleLogout(req, io, alloc);
    } else if (http.pathUnder(path, "/images")) |sub| {
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
    if (try route(&req, io, alloc, &b)) |k| streams.drop(&hub, k);
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

/// The value of response header `name`, or null.
fn responseHeader(response: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn responseBody(response: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[head_end + 4 ..];
}

test "every embedded asset is kept by the browser and asked about each use: ETag, no-cache, 304 (metal-vmm QUEUE 158)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // /game and /puzzles serve their scripts to a player only.
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const me = try signedUid(a, try player.allocate(io, a, "Ada"));
    const paths = [_][]const u8{
        "/chat/chat.js",         "/chat/colors.js",         "/tutorial/tutorial.js", "/game/elm.js",
        "/game/engine.js",       "/game/engine_glue.js",    "/driving/blitter.js",   "/driving/safari.wasm",
        "/chess/board.js",       "/chess/knight.wasm",      "/chess/queens.wasm",    "/puzzles/puzzle.js",
        "/puzzles/engine.js",    "/puzzles/engine_glue.js", "/puzzles/solver.wasm",  "/delivery/app.js",
        "/delivery/solver.wasm",
    };
    for (paths) |path| {
        errdefer std.debug.print("asset {s}\n", .{path});
        const first = try serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ path, me }));
        try testing.expectEqualStrings("200 OK", status(first));
        try testing.expectEqualStrings("no-cache", responseHeader(first, "cache-control") orelse "");
        const tag = responseHeader(first, "etag") orelse return error.NoETag;
        try testing.expect(tag.len > 2 and tag[0] == '"' and tag[tag.len - 1] == '"');

        const again = try serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nIf-None-Match: {s}\r\n\r\n", .{ path, me, tag }));
        try testing.expectEqualStrings("304 Not Modified", status(again));
        try testing.expectEqualStrings("", responseBody(again));
        try testing.expectEqualStrings(tag, responseHeader(again, "etag") orelse "");

        const other = try serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nIf-None-Match: \"0\"\r\n\r\n", .{ path, me }));
        try testing.expectEqualStrings("200 OK", status(other));
        try testing.expectEqualStrings(responseBody(first), responseBody(other));
    }
}

test "every page names its scripts by their bytes, and a script asked for by its hash is never asked about again: immutable (no GET at all)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = @import("mem_meter.zig").useForTest(std.heap.page_allocator); // a send allocates through it
    defer meter.restore();
    // A player for the games; two members and a topic between them for chat.
    const me = try signedUid(a, try player.allocate(io, a, "Ada"));
    const ada = try users.allocateUser(io, a, "Ada");
    try users.setUserPassword(io, a, ada, "a password for Ada");
    const bo = try users.allocateUser(io, a, "Bo");
    try users.setUserPassword(io, a, bo, "a password for Bo");
    const cookies = try std.fmt.allocPrint(a, "{s}; gopher_auth={s}", .{ me, (try users.signSessionNow(io, a, ada)).? });
    const dm = try std.fmt.allocPrint(a, "/chat/c/{s}_{s}/scripts", .{ ada, bo });
    const body = "markdown=hello";
    const sent = try serve(a, io, try std.fmt.allocPrint(a, "POST {s}/send HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ dm, cookies, body.len, body }));
    try testing.expect(status(sent)[0] == '2' or status(sent)[0] == '3');

    const pages = [_][]const u8{
        dm,          "/chat/recent", "/chat/images", "/chat/code",    "/chat/docs",    "/chat/links",
        "/game",     "/puzzles",     "/driving",     "/chess/knight", "/chess/queens", "/delivery",
        "/tutorial",
    };
    for (pages) |page| {
        errdefer std.debug.print("page {s}\n", .{page});
        const got = try UidSite.ask(a, io, page, cookies);
        try testing.expectEqualStrings("200 OK", status(got));
        const html = responseBody(got);
        var scripts: u32 = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, html, at, "<script")) |tag| {
            const close = std.mem.indexOfScalarPos(u8, html, tag, '>') orelse return error.UnclosedTag;
            at = close;
            const attrs = html[tag..close];
            const src_at = std.mem.indexOf(u8, attrs, "src=\"") orelse continue;
            const src_from = src_at + "src=\"".len;
            const src = attrs[src_from .. std.mem.indexOfScalarPos(u8, attrs, src_from, '"') orelse return error.UnclosedSrc];
            if (src.len == 0 or src[0] != '/') continue;
            errdefer std.debug.print("script {s}\n", .{src});
            scripts += 1;
            const q = std.mem.indexOf(u8, src, "?h=") orelse return error.NoHash;
            const asked = try UidSite.ask(a, io, src, cookies);
            try testing.expectEqualStrings("200 OK", status(asked));
            try testing.expectEqualStrings("public, max-age=31536000, immutable", responseHeader(asked, "cache-control") orelse "");
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "\"{s}\"", .{src[q + 3 ..]}), responseHeader(asked, "etag") orelse "");
            // The same path with another hash: today's bytes, asked about each use.
            const stale = try UidSite.ask(a, io, try std.fmt.allocPrint(a, "{s}?h=0", .{src[0..q]}), cookies);
            try testing.expectEqualStrings("200 OK", status(stale));
            try testing.expectEqualStrings("no-cache", responseHeader(stale, "cache-control") orelse "");
            try testing.expectEqualStrings(responseBody(asked), responseBody(stale));
        }
        try testing.expect(scripts > 0);
    }
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

    // The fallthrough. "/drivingX" must NOT reach /driving — http.pathUnder wants a
    // boundary, and this is the case that rule exists for.
    try testing.expectEqualStrings("404 Not Found", status(try get(a, io, "/nope")));
    try testing.expectEqualStrings("404 Not Found", status(try get(a, io, "/drivingX")));

    // Only "/" is the index; the notFound fallthrough catches everything else.
    // The home page reads pages/home.txt from the repo's root, and a test runs
    // in zig-server/, where it is not: so here "/" is the home handler's own
    // 500 ("Home unavailable"), never the fallthrough's 404. (It answered 200
    // with that page until a failed render became a 500, which is how this
    // test came to pass on a page that never rendered.)
    const index = try get(a, io, "/");
    try testing.expect(!std.mem.eql(u8, status(index), "404 Not Found"));
    try testing.expect(std.mem.indexOf(u8, index, "Home unavailable") != null or std.mem.eql(u8, status(index), "200 OK"));
}

test "route: a query string never changes which arm is taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // http.pathOf's whole job: the asset URLs carry their hash, ?h= (http.hashedSrc).
    try testing.expectEqualStrings("200 OK", status(try get(a, io, "/tutorial?h=0")));
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

test "route: ADMIN_ONLY — a logged-in non-admin member is refused the secret-bearing screens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();

    // A real, AUTHORIZED member — uid 2, with a password and a valid signed
    // session — not a guest. `/admin/backup` holds every password hash and
    // the session secret, so the gate that keeps a member out of it (and out
    // of /admin/secret and /admin/apikey) is the one that matters most for a
    // secret leak (QUEUE.md item 92; the gate is admin_ui.requireAdmin, which
    // 404s a uid that is not "1"). The anonymous/guest case is above; this is
    // the member case, which a bare gopher_uid cannot stand in for.
    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});

    for ([_][]const u8{ "/admin", "/admin/backup", "/admin/secret", "/admin/retire", "/admin/apikey", "/admin/host", "/admin/lynrummy", "/admin/search?key=lay" }) |path| {
        const resp = try UidSite.ask(a, io, path, member);
        try testing.expect(std.mem.indexOf(u8, resp, "200 OK") == null); // never served to a member
        try testing.expect(std.mem.indexOf(u8, resp, "$2") == null); // no bcrypt hash in the body
        try testing.expect(std.mem.indexOf(u8, resp, UidSite.secret) == null); // nor the session secret
    }
}

// ── gopher_uid, signed (uid_cookie.zig) ──────────────────────────────────────

/// A site in a temporary folder, every root pointed at it, with a session
/// secret; `deinit` puts the roots back for the rest of the test binary.
const UidSite = struct {
    tmp: testing.TmpDir,
    saved: roots.Saved,
    base: []const u8,
    forgot: @import("game_limits.zig").Forgot,

    const storage = @import("storage.zig");
    const chat_store = @import("chat_store.zig");
    const disk = @import("store.zig");
    const game_limits = @import("game_limits.zig");
    const secret = "a session secret of thirty-two bytes or more, for router tests";

    fn init(a: std.mem.Allocator, io: Io) !UidSite {
        var s: UidSite = .{ .tmp = testing.tmpDir(.{}), .saved = undefined, .base = undefined, .forgot = undefined };
        s.base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &s.tmp.sub_path });
        s.saved = try roots.pointForTest(a, s.base);
        errdefer s.saved.restore();
        try disk.write(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" }), secret, .{});
        s.forgot = UidSite.game_limits.forgetForTest(); // what it kept was measured under other roots
        return s;
    }

    fn deinit(s: *UidSite) void {
        s.forgot.end();
        s.saved.restore();
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
        const p = std.fs.path.join(a, &.{ player.player_root, id, "signed" }) catch return false;
        return disk.has(io, a, p) catch false;
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
    try testing.expectEqualStrings(id, uid_cookie.verify(UidSite.secret, signed, nowSecs(io)).?);
    try testing.expect(UidSite.marked(a, io, id));

    // The signed cookie is the player.
    const with_signed = try std.fmt.allocPrint(a, "gopher_uid={s}", .{signed});
    const page = try UidSite.ask(a, io, "/play", with_signed);
    try testing.expectEqualStrings("200 OK", status(page));
    try testing.expect(playingAs(page, "Nikhil"));

    // The same unsigned cookie again within the grace (the answer may have
    // been lost): re-signed again. Once the grace is over: no one.
    const lost = try UidSite.ask(a, io, "/play", unsigned);
    try testing.expectEqualStrings("303 See Other", status(lost));
    try testing.expectEqualStrings(id, uid_cookie.verify(UidSite.secret, setUid(lost).?, nowSecs(io)).?);
    const marker = try std.fs.path.join(a, &.{ player.player_root, id, "signed" });
    try UidSite.disk.replace(io, a, marker, "1790000000\n", .{}); // signed long ago
    const again = try UidSite.ask(a, io, "/play", unsigned);
    try testing.expectEqualStrings("200 OK", status(again));
    try testing.expect(!playingAs(again, "Nikhil"));
    try testing.expect(setUid(again) == null);
    const game_page = try UidSite.ask(a, io, "/game", unsigned);
    try testing.expect(std.mem.indexOf(u8, game_page, "location: /play?next=/game") != null);

    // A POST with it is never the re-identification: no redirect, no cookie.
    const other = try player.allocate(io, a, "Debbie");
    const post = try serve(a, io, try std.fmt.allocPrint(a, "POST /play HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid={s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n", .{other}));
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
    const post = try std.fmt.allocPrint(a, "POST /login/full HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid=7\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ post_body.len, post_body });

    // Unsigned, straight to the POST: the stranger form, and no password set.
    const forged = try serve(a, io, post);
    try testing.expect(std.mem.indexOf(u8, forged, upgrade) == null);
    try testing.expect(!try users.isMember(io, a, "7"));

    // The guest's own first GET re-signs, and the signed cookie upgrades.
    const first = try UidSite.ask(a, io, "/login/full", "gopher_uid=7");
    try testing.expectEqualStrings("303 See Other", status(first));
    const signed = setUid(first) orelse return error.NoSetCookie;
    const page = try UidSite.ask(a, io, "/login/full", try std.fmt.allocPrint(a, "gopher_uid={s}", .{signed}));
    try testing.expect(std.mem.indexOf(u8, page, upgrade) != null);

    // After it, the unsigned spelling is the stranger form, POST or GET.
    try testing.expect(std.mem.indexOf(u8, try serve(a, io, post), upgrade) == null);
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/login/full", "gopher_uid=7"), upgrade) == null);
    try testing.expect(!try users.isMember(io, a, "7"));
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
    try player.mirror(io, a, "1", "Steve");
    // The agent.
    try users.setUserName(io, a, "3", "Claude");
    try player.mirror(io, a, "3", "Claude");
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

    const r = try serve(a, io, "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 23\r\n\r\nname=Nikhil&next=%2Fgame");
    try testing.expectEqualStrings("303 See Other", status(r));
    const v = setUid(r) orelse return error.NoSetCookie;
    const id = uid_cookie.verify(UidSite.secret, v, nowSecs(io)) orelse return error.Unsigned;
    try testing.expect(UidSite.marked(a, io, id));
    // Its unsigned spelling is refused from the start: not re-signed, even
    // within a re-sign's grace, since this id never had an unsigned cookie.
    const bare = try UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{id}));
    try testing.expectEqualStrings("200 OK", status(bare));
    try testing.expect(setUid(bare) == null);
    try testing.expect(!playingAs(bare, "Nikhil"));
    // With no session secret, nothing is minted: no unsigned cookie instead.
    try removeSecret(a, io);
    const none = try serve(a, io, "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 23\r\n\r\nname=Debbie&next=%2Fgame");
    try testing.expectEqualStrings("500 Internal Server Error", status(none));
    try testing.expect(setUid(none) == null);
}

fn removeSecret(a: std.mem.Allocator, io: Io) !void {
    try UidSite.disk.remove(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" }));
}

// ── the game store's growth (gopher-metal QUEUE item 52) ─────────────────────

fn nowSecs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// A signed gopher_uid cookie for `id`, as /play would have set: signed an
/// hour ago, so it is inside its lifetime whenever the tests run.
fn signedUid(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    return std.fmt.allocPrint(a, "gopher_uid={s}", .{try uid_cookie.sign(a, UidSite.secret, id, nowSecs(threaded.io()) - 3600)});
}

fn postAs(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    return serve(a, io, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body }));
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
    try testing.expect(!try UidSite.disk.has(io, a, games));

    // An id never offered makes nothing.
    try testing.expectEqualStrings("404 Not Found", status(try postAs(a, io, "/puzzles/sessions/5/puzzles/0/actions", me, "1) x")));
    try testing.expect(!try UidSite.disk.has(io, a, games));

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
    try testing.expect(!try UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "2" })));
    try testing.expect(!try UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ games, "puzzle" })));

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
    const host_space = free_space.save();
    defer host_space.restore();
    free_space.reader = lowDisk;
    const third = try player.allocate(io, a, "Gus");
    const floor = try postAs(a, io, "/game/new-session", try signedUid(a, third), "state");
    try testing.expectEqualStrings("507 Insufficient Storage", status(floor));
    try testing.expect(std.mem.indexOf(u8, floor, "low on disk") != null);
    const named = try serve(a, io, "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 21\r\n\r\nname=Ann&next=%2Fgame");
    try testing.expectEqualStrings("303 See Other", status(named));
}

fn lowDisk() ?free_space.Space {
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
    const host_proxy = client_address.save();
    defer host_proxy.restore();
    client_address.trusted_proxy = "10.0.0.1";

    const Name = struct {
        fn post(al: std.mem.Allocator, i: Io, peer: []const u8, xff: []const u8) ![]const u8 {
            const body = "name=Ann&next=%2Fgame";
            return serveFrom(al, i, try std.fmt.allocPrint(al, "POST /play HTTP/1.1\r\nHost: x\r\n{s}Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ xff, body.len, body }), peer);
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
    // What the proxy forwards that is not an address is not believed: the
    // request counts against the proxy itself, so six different pieces of
    // garbage are one address, and the sixth is refused.
    for (0..limits.players_per_hour) |k|
        try testing.expectEqualStrings("303 See Other", status(try Name.post(a, io, "10.0.0.1", try std.fmt.allocPrint(a, "X-Forwarded-For: 192.0.2.11, not-one-{d}\r\n", .{k}))));
    try testing.expectEqualStrings("429 Too Many Requests", status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 192.0.2.11, not-one-9\r\n")));

    // Game writes: 20 MB from one address an hour, across players.
    const ids = [_][]const u8{ try player.allocate(io, a, "One"), try player.allocate(io, a, "Two") };
    const big = try a.alloc(u8, 200 * 1024);
    @memset(big, 's');
    var sent: u64 = 0;
    var refused: ?[]const u8 = null;
    var n: usize = 0;
    while (refused == null) : (n += 1) {
        const r = try serveFrom(a, io, try std.fmt.allocPrint(a, "POST /game/new-session HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ try signedUid(a, ids[n % 2]), big.len, big }), "203.0.113.7");
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
    try testing.expectEqualStrings("200 OK", status(try serveFrom(a, io, try std.fmt.allocPrint(a, "POST /game/new-session HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 5\r\n\r\nstate", .{try signedUid(a, ids[0])}), "198.51.100.1")));
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

test "route: start does the host's setup in one call: the data pointed at, every session's record, search's index, the floor and the proxy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(a);
    defer meter.restore();
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const host_space = free_space.save();
    defer host_space.restore();
    const host_proxy = client_address.save();
    defer host_proxy.restore();
    const chat_store = @import("chat_store.zig");
    const disk = @import("store.zig");
    const md = try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.md" });
    try disk.write(io, a, md, "MSG_ChitChat_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nhello world", .{});
    var started = try start(io, .{
        .roots = .{ .data_dir = try std.fs.path.join(a, &.{ site.base, "data" }), .auth_dir = try std.fs.path.join(a, &.{ site.base, "auth" }) },
        .floor = .none_for_a_test,
        .trusted_proxy = "10.0.0.2",
    });
    _ = &started;
    try testing.expectEqual(@as(usize, 1), started.backfilled);
    try testing.expect(try disk.has(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.count" })));
    try testing.expectEqual(@as(usize, 1), started.search.?.messages);
    try testing.expectEqual(@as(?*const fn () ?free_space.Space, null), free_space.reader);
    try testing.expectEqualStrings("10.0.0.2", client_address.trusted_proxy.?);
}

test "route: /admin/search finds a key in every conversation the admin can see, DMs and channels, ASCII case folded, and nowhere else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const me = try adminSession(a, io);
    const chat_store = @import("chat_store.zig");
    const disk = @import("store.zig");
    // Two more members; the admin is in channel "general", not in "quiet".
    for ([_][2][]const u8{ .{ "2", "Debbie" }, .{ "3", "Apoorva" } }) |m| {
        try users.setUserName(io, a, m[0], m[1]);
        try users.setUserPassword(io, a, m[0], "pw");
    }
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n3\n", .{});
    const transcripts = [_]struct { dir: []const u8, sid: []const u8, body: []const u8 }{
        .{ .dir = "1_2", .sid = "ChitChat", .body = "MSG_ChitChat_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nthe page LAYOUT is off" ++ chat_store.sep ++ "MSG_ChitChat_2\nfrom: Claude\ndate: 2026-10-10T00:01:00Z\n\nnothing to see" },
        .{ .dir = "channels/general", .sid = "Trips", .body = "MSG_Trips_1\nfrom: Debbie\ndate: 2026-10-10T00:02:00Z\n\na long layover in Denver" ++ chat_store.sep ++ "MSG_Trips_2\nfrom: Debbie\ndate: 2026-10-10T00:02:30Z\n\n<script>alert(1)</script> lay" },
        .{ .dir = "2_3", .sid = "Cards", .body = "MSG_Cards_1\nfrom: Apoorva\ndate: 2026-10-10T00:03:00Z\n\ndeal the seven" },
        // Not the admin's: a DM between two others, and a channel the admin is not in.
        .{ .dir = "2_3", .sid = "Private", .body = "MSG_Private_1\nfrom: Debbie\ndate: 2026-10-10T00:04:00Z\n\nthe layaway plan" },
        .{ .dir = "channels/quiet", .sid = "Hush", .body = "MSG_Hush_1\nfrom: Apoorva\ndate: 2026-10-10T00:05:00Z\n\na layer cake" },
    };
    for (transcripts) |t| {
        const path = try std.fs.path.join(a, &.{ chat_store.chat_root, t.dir, "sessions", try std.fmt.allocPrint(a, "{s}.md", .{t.sid}) });
        try disk.write(io, a, path, t.body, .{});
    }
    const got = try UidSite.ask(a, io, "/admin/search?key=lay", me);
    try testing.expectEqualStrings("200 OK", status(got));
    try testing.expect(std.mem.indexOf(u8, got, "/chat/c/1_2/ChitChat#msg-ChitChat_1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "/channel/general/Trips#msg-Trips_1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "ChitChat_2") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Private_1") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Hush_1") == null);
    try testing.expect(std.mem.indexOf(u8, got, "3 messages match, of 4 in 2 transcripts") != null);
    // A message's text is escaped on the page.
    try testing.expect(std.mem.indexOf(u8, got, "&lt;script&gt;alert(1)&lt;/script&gt; lay") != null);
    try testing.expect(std.mem.indexOf(u8, got, "<script>alert") == null);
    // **ONLY A GET FROM THIS SITE SEARCHES**: a HEAD, and a link from another
    // site that the admin's cookie follows, get the form and read nothing.
    const admin_search = @import("admin_search.zig");
    const read_before = admin_search.transcripts_read;
    const head = try serve(a, io, try std.fmt.allocPrint(a, "HEAD /admin/search?key=lay HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expectEqualStrings("200 OK", status(head));
    try testing.expectEqual(read_before, admin_search.transcripts_read);
    const cross = try serve(a, io, try std.fmt.allocPrint(a, "GET /admin/search?key=lay HTTP/1.1\r\nHost: x\r\nSec-Fetch-Site: cross-site\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expect(std.mem.indexOf(u8, cross, "messages match") == null);
    try testing.expect(std.mem.indexOf(u8, cross, "does not run; press Search") != null);
    const typed = try serve(a, io, try std.fmt.allocPrint(a, "GET /admin/search?key=lay HTTP/1.1\r\nHost: x\r\nSec-Fetch-Site: none\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expect(std.mem.indexOf(u8, typed, "3 messages match") != null);
}

test "route: Recent's Who cell names the last author where the .count is behind its transcript, \"You\" for the viewer (the box's must-fix)" {
    // A sidecar write that failed leaves the .count one message behind. With
    // .lastauthor gone (153(1)) the cell showed nobody; the author is found
    // by the last message's name, as login finds members.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    const debbie = try memberSession(a, io, "2", "Debbie");
    const first = "MSG_ChitChat_1\nfrom: Debbie\ndate: 2026-10-10T00:00:00Z\n\nhello";
    try writeTranscript(a, io, "1_2", "ChitChat", &.{}); // the folder
    const md = try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.md" });
    try UidSite.disk.write(io, a, md, first ++ chat_store.sep ++ "MSG_ChitChat_2\nfrom: Steve\ndate: 2026-10-10T00:01:00Z\n\nhi back", .{});
    // The .count as it stood after the first message: one behind.
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.count" }), try std.fmt.allocPrint(a, "1 {d}\n0 2\n", .{first.len}), .{});

    const mine = try UidSite.ask(a, io, "/chat/recent", steve);
    try testing.expect(std.mem.indexOf(u8, mine, "\"who\":\"You\"") != null);
    const theirs = try UidSite.ask(a, io, "/chat/recent", debbie);
    try testing.expect(std.mem.indexOf(u8, theirs, "\"who\":\"Steve\"") != null);
}

// ── search (metal-vmm QUEUE 155) ─────────────────────────────────────────────

/// A member's session for UidSite.
fn memberSession(a: std.mem.Allocator, io: Io, uid: []const u8, name: []const u8) ![]const u8 {
    try users.setUserName(io, a, uid, name);
    try users.setUserPassword(io, a, uid, "pw");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, uid, now)});
}

/// A transcript as the store lays it out: one message a body, numbered from 1.
fn writeTranscript(a: std.mem.Allocator, io: Io, dir: []const u8, sid: []const u8, bodies: []const []const u8) !void {
    const chat_store = @import("chat_store.zig");
    var t: std.ArrayList(u8) = .empty;
    for (bodies, 1..) |body, n| {
        if (n > 1) try t.appendSlice(a, chat_store.sep);
        try t.print(a, "MSG_{s}_{d}\nfrom: Someone\ndate: 2026-10-10T00:{d:0>2}:00Z\n\n{s}", .{ sid, n, n % 60, body });
    }
    const path = try std.fs.path.join(a, &.{ chat_store.chat_root, dir, "sessions", try std.fmt.allocPrint(a, "{s}.md", .{sid}) });
    try UidSite.disk.write(io, a, path, t.items, .{});
}

test "route: search suggests and finds only in what the viewer can see; a word only in another pair's DM is neither (metal-vmm 155(d))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const chat_store = @import("chat_store.zig");

    const me = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    _ = try memberSession(a, io, "3", "Apoorva");
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n3\n", .{});
    try writeTranscript(a, io, "1_2", "ChitChat", &.{ "the page LAYOUT is off", "\u{201C}Layover\u{201D} in Denver?" });
    try writeTranscript(a, io, "channels/general", "Trips", &.{"a layout, again"});
    // Not mine: another pair's DM, and a channel I am not in.
    try writeTranscript(a, io, "2_3", "Private", &.{"the layaway plan, secretly"});
    try writeTranscript(a, io, "channels/quiet", "Hush", &.{"a layer cake, secretly"});

    const words = try UidSite.ask(a, io, "/chat/search/words?prefix=LAY", me);
    try testing.expectEqualStrings("200 OK", status(words));
    try testing.expect(std.mem.indexOf(u8, words, "{\"word\":\"layout\",\"count\":2}") != null);
    try testing.expect(std.mem.indexOf(u8, words, "{\"word\":\"layover\",\"count\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, words, "layaway") == null);
    try testing.expect(std.mem.indexOf(u8, words, "layer") == null);
    // A word in what I can see and in what I cannot: counted in mine only
    // ("the" is in 1_2 once, and in 2_3).
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/chat/search/words?prefix=the", me), "{\"word\":\"the\",\"count\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/chat/search/messages?word=the", me), "\"matched\":1,") != null);

    const found = try UidSite.ask(a, io, "/chat/search/messages?word=layout", me);
    try testing.expect(std.mem.indexOf(u8, found, "\"matched\":2") != null);
    try testing.expect(std.mem.indexOf(u8, found, "\"conv\":\"/chat/c/1_2\",\"kind\":\"dm\",\"sid\":\"ChitChat\",\"id\":\"ChitChat_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, found, "\"conv\":\"/channel/general\",\"kind\":\"channel\",\"sid\":\"Trips\",\"id\":\"Trips_1\"") != null);
    // **THE LEAK**: words only in what others can see.
    chat_search.forgetAll();
    for ([_][]const u8{ "/chat/search/messages?word=secretly", "/chat/search/messages?word=layaway", "/chat/search/words?prefix=secr" }) |target| {
        const got = try UidSite.ask(a, io, target, me);
        try testing.expectEqualStrings("200 OK", status(got));
        try testing.expect(std.mem.indexOf(u8, got, "secretly") == null or std.mem.indexOf(u8, got, "\"word\":\"secretly\",\"matched\":0,\"unreadable\":0,\"messages\":[]") != null);
        try testing.expect(std.mem.indexOf(u8, got, "layaway plan") == null);
        try testing.expect(std.mem.indexOf(u8, got, "\"count\"") == null);
    }
    // And one who can see them finds them.
    const deb = try memberSession(a, io, "2", "Debbie");
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/chat/search/messages?word=secretly", deb), "\"matched\":2") != null);

    // **A MESSAGE THAT LANDS IS FOUND**, without a build from the disk.
    var hub = Hub.init(io, a);
    var bus = Bus.of(&hub);
    const meta = chat_store.ConvMeta{ .kind = .dm, .members = &[_][]const u8{ "1", "2" } };
    _ = try chat_store.appendMessage(io, a, &bus, meta, try chat_store.dmConvDir(a, "1_2"), "1_2", "ChitChat", "Steve", "1", "zeppelins, tonight", "");
    chat_search.forgetAll();
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/chat/search/messages?word=zeppelins", me), "\"matched\":1") != null);

    // **A FEW SEARCHES A SECOND**, then 429.
    chat_search.forgetAll();
    var refused = false;
    for (0..chat_search.per_second + 1) |_| {
        if (std.mem.eql(u8, status(try UidSite.ask(a, io, "/chat/search/words?prefix=la", me)), "429 Too Many Requests")) refused = true;
    }
    try testing.expect(refused);
}

test "search agrees with /admin/search: for every word, the baseline's messages that hold it (metal-vmm 155(c))" {
    // /admin/search matches a key as a substring ("lay" finds "player"); the
    // index, whole words. So for every key that is a word of the corpus, and
    // every viewer: the index's messages are exactly the baseline's whose
    // words include the key. The corpus stays under the baseline's 500
    // listed, and no transcript is too large for it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const tokens = @import("search_tokens.zig");
    const admin_search = @import("admin_search.zig");
    const chat_store = @import("chat_store.zig");
    const meter = mem_meter.useForTest(testing.allocator);
    defer meter.restore();
    const emptied = search_index.emptyForTest();
    defer emptied.end();

    for ([_][2][]const u8{ .{ "1", "Steve" }, .{ "2", "Debbie" }, .{ "3", "Apoorva" } }) |m| {
        try users.setUserName(io, a, m[0], m[1]);
        try users.setUserPassword(io, a, m[0], "pw");
    }
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n3\n", .{});
    const vocabulary = [_][]const u8{
        "Layout",      "layout,",     "\u{201C}layout\u{201D}", "lay", "player", "LAY!", "(lay)", "layer",    "don't",                "don\u{2019}t",
        "caf\u{00E9}", "CAF\u{00C9}", "\u{65E5}\u{672C}",       "a",   "x1",     "e.g.", "3.14",  "**bold**", "\u{2014}dash\u{2014}", "plan",
    };
    const places = [_][2][]const u8{ .{ "1_2", "Alpha" }, .{ "1_2", "Beta" }, .{ "1_3", "Gamma" }, .{ "2_3", "Delta" }, .{ "channels/general", "Trips" }, .{ "channels/quiet", "Hush" } };
    // The words of each message by where it is: "<base> <sid> <id>".
    var holds: std.StringHashMapUnmanaged([]const u8) = .empty;
    var prng = std.Random.DefaultPrng.init(155);
    const rand = prng.random();
    for (places) |pl| {
        var bodies: std.ArrayList([]const u8) = .empty;
        for (0..rand.intRangeAtMost(usize, 1, 12)) |_| {
            var body: std.ArrayList(u8) = .empty;
            for (0..rand.intRangeAtMost(usize, 1, 8)) |w| {
                if (w > 0) try body.append(a, if (rand.boolean()) ' ' else '\n');
                try body.appendSlice(a, vocabulary[rand.uintLessThan(usize, vocabulary.len)]);
            }
            try bodies.append(a, body.items);
        }
        try writeTranscript(a, io, pl[0], pl[1], bodies.items);
        const base = if (std.mem.startsWith(u8, pl[0], "channels/")) try std.fmt.allocPrint(a, "/channel/{s}", .{pl[0]["channels/".len..]}) else try std.fmt.allocPrint(a, "/chat/c/{s}", .{pl[0]});
        for (bodies.items, 1..) |body, n| try holds.put(a, try std.fmt.allocPrint(a, "{s} {s} {s}_{d}", .{ base, pl[1], pl[1], n }), body);
    }
    // Every key: every word of the corpus, folded.
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    var hit_it = holds.valueIterator();
    while (hit_it.next()) |body| {
        var it = tokens.words(body.*);
        while (it.next()) |w| try keys.put(a, try std.ascii.allocLowerString(a, w), {});
    }
    try testing.expect(keys.count() > 10);
    // Built; then messages that land after it, through appendMessage, as
    // the index takes them (and the disk, which the baseline reads).
    _ = search_index.ready(io, a).?;
    var hub = Hub.init(io, a);
    var bus = Bus.of(&hub);
    for (0..12) |n| {
        const pl = places[rand.uintLessThan(usize, places.len)];
        const channel = std.mem.startsWith(u8, pl[0], "channels/");
        const meta = chat_store.ConvMeta{ .kind = if (channel) .channel else .dm, .members = &[_][]const u8{} };
        var body: std.ArrayList(u8) = .empty;
        for (0..rand.intRangeAtMost(usize, 1, 6)) |w| {
            if (w > 0) try body.append(a, ' ');
            try body.appendSlice(a, vocabulary[rand.uintLessThan(usize, vocabulary.len)]);
        }
        const dir = try std.fs.path.join(a, &.{ chat_store.chat_root, pl[0] });
        const m = try chat_store.appendMessage(io, a, &bus, meta, dir, pl[0], pl[1], "Someone", "1", body.items, "");
        const base = if (channel) try std.fmt.allocPrint(a, "/channel/{s}", .{pl[0]["channels/".len..]}) else try std.fmt.allocPrint(a, "/chat/c/{s}", .{pl[0]});
        try holds.put(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ base, pl[1], m.id }), body.items);
        _ = n;
    }
    hit_it = holds.valueIterator();
    while (hit_it.next()) |body| {
        var it = tokens.words(body.*);
        while (it.next()) |w| try keys.put(a, try std.ascii.allocLowerString(a, w), {});
    }
    const idx = search_index.ready(io, a).?;
    var compared: usize = 0;
    for ([_][]const u8{ "1", "2", "3" }) |who| {
        const reach = try chat_store.visibleConvs(io, a, who);
        var key_it = keys.keyIterator();
        while (key_it.next()) |k| {
            const base_r = try admin_search.search(io, a, who, k.*);
            try testing.expect(base_r.matched == base_r.hits.len); // under its cap
            try testing.expectEqual(@as(usize, 0), base_r.unreadable + base_r.too_big);
            var want: std.StringHashMapUnmanaged(void) = .empty;
            for (base_r.hits) |h| {
                const where = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ h.base, h.sid, h.id });
                var it = tokens.words(holds.get(where).?);
                var has = false;
                while (it.next()) |w| {
                    if (std.ascii.eqlIgnoreCase(w, k.*) and w.len == k.len) has = true;
                }
                if (has) try want.put(a, where, {});
            }
            const got = try idx.messagesFor(a, reach, k.*, 10_000, .{});
            try testing.expectEqual(got.matched, got.hits.len);
            var got_set: std.StringHashMapUnmanaged(void) = .empty;
            for (got.hits) |h| try got_set.put(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ h.conv.base, h.msg.sid, h.msg.id }), {});
            if (want.count() != got_set.count()) {
                std.debug.print("viewer {s}, key \"{s}\": the baseline's messages holding it {d}, the index's {d}\n", .{ who, k.*, want.count(), got_set.count() });
                return error.Disagree;
            }
            var want_it = want.keyIterator();
            while (want_it.next()) |w| try testing.expect(got_set.contains(w.*));
            // And the words route counts it so (the box's review of 155).
            var counted: usize = 0;
            for (try idx.wordsFor(a, reach, k.*, 100_000)) |wc| {
                if (std.mem.eql(u8, wc.word, k.*)) counted = wc.count;
            }
            try testing.expectEqual(want.count(), counted);
            compared += 1;
        }
    }
    try testing.expect(compared > 30);
}

test "route: only a member's own session is the admin; a non-member's session, or a gopher_uid, is no one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const ask = struct {
        fn admin(al: std.mem.Allocator, i: Io, cookie: []const u8) ![]const u8 {
            return serve(al, i, try std.fmt.allocPrint(al, "GET /admin HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{cookie}));
        }
    };

    // uid 1 with a name and no password is not a member: a session signed
    // rightly for it names no one.
    try users.setUserName(io, a, "1", "Steve");
    const early = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "1", now)});
    try testing.expectEqualStrings("303 See Other", status(try ask.admin(a, io, early)));

    // Once a member, the session is the admin; a signed gopher_uid for the
    // same id is not a session, and is no one here.
    const me = try adminSession(a, io);
    try testing.expectEqualStrings("200 OK", status(try ask.admin(a, io, me)));
    try testing.expectEqualStrings("303 See Other", status(try ask.admin(a, io, try signedUid(a, "1"))));
}

fn postForm(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    return serve(a, io, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body }));
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

test "route: one address may have 3 legacy cookies re-signed an hour, then 429" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const limits = UidSite.game_limits;

    var ids: [5][]const u8 = undefined;
    for (&ids) |*id| id.* = try player.allocate(io, a, "Nikhil");
    const from = struct {
        fn get(al: std.mem.Allocator, i: Io, id: []const u8, peer: []const u8) ![]const u8 {
            return serveFrom(al, i, try std.fmt.allocPrint(al, "GET /play HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid={s}\r\n\r\n", .{id}), peer);
        }
    };
    for (ids[0..limits.resigns_per_hour]) |id|
        try testing.expectEqualStrings("303 See Other", status(try from.get(a, io, id, "203.0.113.7")));
    // The sweep's next id: refused, saying why, and not marked, so its owner
    // can still come back.
    const swept = try from.get(a, io, ids[3], "203.0.113.7");
    try testing.expectEqualStrings("429 Too Many Requests", status(swept));
    try testing.expect(std.mem.indexOf(u8, swept, "renewed") != null);
    try testing.expect(setUid(swept) == null);
    try testing.expect(!UidSite.marked(a, io, ids[3]));
    // Its owner, from their own address, is re-signed.
    try testing.expectEqualStrings("303 See Other", status(try from.get(a, io, ids[3], "198.51.100.1")));
    // And an ordinary visit from the swept-out address is untouched.
    try testing.expectEqualStrings("200 OK", status(try serveFrom(a, io, "GET /play HTTP/1.1\r\nHost: x\r\n\r\n", "203.0.113.7")));
}

test "route: /admin/secret changes the secret: members log in again, players are re-signed for the days given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const me = try adminSession(a, io);
    const id = try player.allocate(io, a, "Nikhil");
    const old_uid = try signedUid(a, id); // signed with the secret before the change
    const secret_path = try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" });

    // The form; a wrong password and bad days change nothing.
    try testing.expect(std.mem.indexOf(u8, try UidSite.ask(a, io, "/admin/secret", me), "type=\"password\"") != null);
    try testing.expectEqualStrings("403 Forbidden", status(try postForm(a, io, "/admin/secret", me, "password=wrong&days=7")));
    try testing.expectEqualStrings("400 Bad Request", status(try postForm(a, io, "/admin/secret", me, "password=hunter2&days=abc")));
    try testing.expectEqualStrings("400 Bad Request", status(try postForm(a, io, "/admin/secret", me, "password=hunter2&days=91")));
    try testing.expectEqualStrings(UidSite.secret, try UidSite.disk.read(io, a, secret_path, .limited(256)));
    // Nobody but the admin reaches it.
    try testing.expectEqualStrings("303 See Other", status(try postForm(a, io, "/admin/secret", "gopher_uid=1", "password=hunter2&days=7")));

    // The change.
    const done = try postForm(a, io, "/admin/secret", me, "password=hunter2&days=7");
    try testing.expectEqualStrings("200 OK", status(done));
    const new_secret = try UidSite.disk.read(io, a, secret_path, .limited(256));
    try testing.expect(!std.mem.eql(u8, new_secret, UidSite.secret));
    try testing.expectEqual(@as(usize, 64), new_secret.len);

    // The admin's session has ended; the password still logs in.
    try testing.expectEqualStrings("303 See Other", status(try UidSite.ask(a, io, "/admin", me)));
    const relogin = try postForm(a, io, "/login/full", "x=y", "name=Steve&password=hunter2&action=login");
    try testing.expect(std.mem.indexOf(u8, relogin, "set-cookie: gopher_auth=") != null);

    // The player's old cookie still names them, on a POST too, and a GET
    // re-signs it with the new secret.
    try testing.expect(playingAs(try postForm(a, io, "/play", old_uid, ""), "Nikhil"));
    const renewed = try UidSite.ask(a, io, "/play", old_uid);
    try testing.expectEqualStrings("303 See Other", status(renewed));
    const fresh = setUid(renewed) orelse return error.NoSetCookie;
    try testing.expectEqualStrings(id, uid_cookie.verify(new_secret, fresh, nowSecs(io)).?);
    try testing.expect(playingAs(try UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{fresh})), "Nikhil"));

    // Once the days are over, the old cookie names no one.
    try UidSite.disk.replace(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret.previous-until" }), "1\n", .{});
    const late = try UidSite.ask(a, io, "/play", old_uid);
    try testing.expectEqualStrings("200 OK", status(late));
    try testing.expect(!playingAs(late, "Nikhil"));
    try testing.expect(setUid(late) == null);
}

test "fs: a doc that cannot be looked at is a server error, never a 404 (metal-vmm QUEUE 114)" {
    // A 404 says "no such doc", and an API client's next save may then
    // replace one that is there (QUEUE 105's pattern, through a wrapper:
    // docs_store.docExists).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const docs_store = @import("docs_store.zig");
    // The docs page allocates through it, and presence keeps a map in it for
    // the life of the process: an arena freed at the test's end would leave
    // the next test that marks someone active a map in freed memory.
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});

    const kept = try docs_store.docPath(a, "2", "kept");
    try UidSite.disk.write(io, a, kept, "# kept\n", .{});
    const fine = try UidSite.ask(a, io, "/chat/docs/kept.md", member);
    try testing.expectEqualStrings("200 OK", status(fine));

    // The same doc, now a link to itself: it cannot be looked at.
    const lost = try docs_store.docPath(a, "2", "lost");
    try std.Io.Dir.cwd().symLink(io, "lost.md", lost, .{});
    const resp = try UidSite.ask(a, io, "/chat/docs/lost.md", member);
    try testing.expect(std.mem.indexOf(u8, status(resp), "404") == null);
    try testing.expect(std.mem.startsWith(u8, status(resp), "5"));
}

/// The host's Io, but every file removal fails: a store whose delete is
/// refused, while reads and writes go on (metal-vmm QUEUE 129).
/// Refused only under paths holding this, when it is set (QUEUE 134(e)).
var refuse_under: []const u8 = "";
/// Or, when set, a file of this name wherever it is, by a full path or by
/// the name alone as std's deleteTree asks (QUEUE 138(f)).
var refuse_named: []const u8 = "";
fn removalsFail(io: Io, vt: *Io.VTable) Io {
    const refused = struct {
        // Not std's failingDirDeleteFile, which answers FileNotFound: that
        // is "already gone", which a revoke rightly takes as done.
        fn deleteFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
            const named = refuse_named.len > 0 and std.mem.eql(u8, std.fs.path.basename(sub_path), refuse_named);
            const under = refuse_named.len == 0 and std.mem.indexOf(u8, sub_path, refuse_under) != null;
            if (!named and !under) return real.?.dirDeleteFile(userdata, dir, sub_path);
            return error.AccessDenied;
        }
        var real: ?*const Io.VTable = null;
    };
    refused.real = io.vtable;
    vt.* = io.vtable.*;
    vt.dirDeleteFile = refused.deleteFile;
    return .{ .userdata = io.userdata, .vtable = vt };
}

test "route: a key revoke whose removal fails is not answered as revoked, and the key is still there to say so (metal-vmm QUEUE 129)" {
    // `clearUserAPIKey` was `store.remove(...) catch {}`, and /settings/apikey
    // then redirected to `?keyrevoked=1`: the member told their key was gone
    // while it went on authenticating.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});
    const key = try users.setUserAPIKey(io, a, "2");

    var vt: Io.VTable = undefined;
    const failing = removalsFail(io, &vt);
    const raw = try std.fmt.allocPrint(a, "POST /settings/apikey HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 8\r\n\r\nrevoke=1", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(failing, a);
    var b = Bus.of(&hub);
    _ = route(&req, failing, a, &b) catch {};
    try out.writer.flush();
    try testing.expect(std.mem.indexOf(u8, out.written(), "keyrevoked") == null);
    try testing.expect(std.mem.startsWith(u8, status(out.written()), "500"));
    // The key is there, and still the key.
    try testing.expectEqualStrings(key, (try users.getUserAPIKey(io, a, "2")).?);
}

test "route: a release whose removals fail is not answered as done, and the account is still there (metal-vmm QUEUE 129)" {
    // Logout's release ran `deleteUserData(...) catch {}`, then deleted the
    // record (each removal itself `catch {}`), then said "logged out": a
    // refused removal left the account logging in, or its data kept, while
    // its member was told both were gone.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});
    const data = try std.fs.path.join(a, &.{ UidSite.storage.data_root, "2", "next-session-id.txt" });
    try UidSite.disk.write(io, a, data, "2\n", .{});

    var vt: Io.VTable = undefined;
    const failing = removalsFail(io, &vt);
    const raw = try std.fmt.allocPrint(a, "POST /logout HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrelease=yes", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(failing, a);
    var b = Bus.of(&hub);
    _ = route(&req, failing, a, &b) catch {};
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, status(out.written()), "500"));
    // The account is there, and still logs in.
    try testing.expect(try users.principalExists(io, a, "2"));
    try testing.expect(users.checkUserPassword(io, a, "2", "hunter2"));
    _ = try UidSite.disk.stat(io, a, data); // and its data, which the release could not remove
}

test "route: a release whose last removal fails leaves an account that can release again, never one gone with its leftovers kept (metal-vmm QUEUE 134(e))" {
    // The account record went first (auth_root: its password), then its
    // private state (users_root). A failure there answered 500 for an
    // account already released: nobody could log in to try again, and the
    // folder stayed. Authority goes last, as the retire's does.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});
    const private = try std.fs.path.join(a, &.{ users.users_root, "2" });
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ private, "upload-bytes" }), "1\n", .{});

    var vt: Io.VTable = undefined;
    refuse_under = private;
    defer refuse_under = "";
    const failing = removalsFail(io, &vt);
    const raw = try std.fmt.allocPrint(a, "POST /logout HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrelease=yes", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(failing, a);
    var b = Bus.of(&hub);
    _ = route(&req, failing, a, &b) catch {};
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, status(out.written()), "500"));
    // Still an account that logs in, to release again.
    try testing.expect(users.checkUserPassword(io, a, "2", "hunter2"));
    // And again, the disk willing: released, nothing left.
    refuse_under = "";
    try testing.expect(std.mem.indexOf(u8, try postForm(a, io, "/logout", member, "release=yes"), "500") == null);
    try testing.expect(!try users.principalExists(io, a, "2"));
    try testing.expect(!try UidSite.disk.has(io, a, private));
}

test "route: a release whose removal inside the account fails keeps the password, whatever order the folder is walked in (metal-vmm QUEUE 138(f))" {
    // The account's folder (auth_root/<id>) went by std's deleteTree, in the
    // order the folder was read: the password could go before a file whose
    // removal then failed, and the account was gone with its leftovers kept.
    // Each of the account's other files is refused in turn: the password
    // goes last, so it is there every time. (QUEUE 134(e)'s test refused all
    // of users_root, which depended on how std's deleteTree walks.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    const account = try std.fs.path.join(a, &.{ users.auth_root, "2" });
    // Thirty files besides it: whatever order a folder is read in, the
    // password is last of them one time in thirty-one, so the walk that
    // removed it before a refused file is seen.
    const others = [_][]const u8{ "name", "api-key", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25", "f26", "f27", "f28" };
    for (others) |refused| {
        try users.setUserPassword(io, a, "2", "hunter2");
        for (others) |f| try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ account, f }), "x", .{});
        const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
        const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});

        var vt: Io.VTable = undefined;
        refuse_named = refused;
        defer refuse_named = "";
        const failing = removalsFail(io, &vt);
        const raw = try std.fmt.allocPrint(a, "POST /logout HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrelease=yes", .{member});
        var reader: std.Io.Reader = .fixed(raw);
        var out: std.Io.Writer.Allocating = .init(a);
        var server = std.http.Server.init(&reader, &out.writer);
        var req = try server.receiveHead();
        req.head.keep_alive = false;
        var hub = Hub.init(failing, a);
        var b = Bus.of(&hub);
        _ = route(&req, failing, a, &b) catch {};
        try out.writer.flush();
        try testing.expect(std.mem.startsWith(u8, status(out.written()), "500"));
        // Still an account that logs in, to release again.
        try testing.expect(users.checkUserPassword(io, a, "2", "hunter2"));
        // And again, the disk willing: released, nothing left.
        refuse_named = "";
        try testing.expect(std.mem.indexOf(u8, try postForm(a, io, "/logout", member, "release=yes"), "500") == null);
        try testing.expect(!try users.principalExists(io, a, "2"));
        try testing.expect(!try UidSite.disk.has(io, a, account));
    }
}

test "route: an error after a request's body was read is answered 500 too, never with silence (metal-vmm QUEUE 127(b))" {
    // Reading the body moves the reader past `received_head`, so that state
    // cannot say whether a head went out: a move whose append fails, after
    // its body was read, was answered with nothing. Here the session's
    // actions.dsl is a folder: the session is there, and the append fails.
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
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/game/new-session", me, "state")));
    const s1 = try std.fs.path.join(a, &.{ UidSite.storage.data_root, id, "lynrummy-elm", "sessions", "1" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ s1, "actions.dsl" }));

    const raw = try std.fmt.allocPrint(a, "POST /game/sessions/1/actions HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 4\r\n\r\nmove", .{me});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    try testing.expect(std.meta.isError(route(&req, io, a, &b)));
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, status(out.written()), "500"));
    // And the writer the router lent the handler is given back.
    try testing.expect(server.out == &out.writer);
}

test "fs: a handler's error is answered 500, never with silence (metal-vmm QUEUE 123)" {
    // On metal, `GET /puzzles -> ReadFailed` reached the console and the
    // client got nothing (the box's durable sweep, seed 173): an error that
    // escapes a handler was dropped by the host. Here a doc that is a
    // folder: it is there, and reading it fails.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const docs_store = @import("docs_store.zig");
    const meter = mem_meter.useForTest(std.heap.page_allocator); // as above: presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, UidSite.secret, "2", now)});
    try std.Io.Dir.cwd().createDirPath(io, try docs_store.docPath(a, "2", "folder"));

    const raw = try std.fmt.allocPrint(a, "GET /chat/docs/folder.md HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    // The error still goes to the host, to log; the client is told first,
    // and told nothing of it (QUEUE 134(f)): its name is the log's.
    try testing.expect(std.meta.isError(route(&req, io, a, &b)));
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, status(out.written()), "500"));
    try testing.expect(std.mem.endsWith(u8, out.written(), "\r\n\r\nThe server failed.\n"));
}

// ── the normalization hunt's app findings (metal-vmm QUEUE 156) ──────────────

test "route: a new topic differing only in case from one there is refused, 409, where the store would merge them (156(a))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expectEqualStrings("409 Conflict", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=plans")));
    try testing.expectEqualStrings("409 Conflict", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=PLANS")));
    try testing.expectEqualStrings("400 Bad Request", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=New")));
}

test "route: a send that would store nothing is refused, 400, and a message is stored as sent (156(b))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // No markdown field at all; one that is only whitespace.
    try testing.expectEqualStrings("400 Bad Request", status(try postAs(a, io, "/chat/c/1_2/Plans/send", steve, "cid=x")));
    try testing.expectEqualStrings("400 Bad Request", status(try postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=+%0A+&cid=x")));
    // A message that began DROP_ON_FLOOR is a message.
    try testing.expectEqualStrings("303 See Other", status(try postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=DROP_ON_FLOOR+is+a+phrase&cid=y")));
    // A code block's indentation stays.
    try testing.expectEqualStrings("303 See Other", status(try postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=++++code%0A++++more&cid=z")));
    const raw = (try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Plans")).?;
    const msgs = try chat_store.decodeChatFile(a, raw);
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("DROP_ON_FLOOR is a phrase", msgs[1].markdown);
    try testing.expectEqualStrings("    code\n    more", msgs[2].markdown);
}

test "route: sign-up refuses a name it would have to change, never registering another (156(e))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const page = try postForm(a, io, "/login/full", "x=y", "name=Bob%3Cx%3E&password=pw&action=register");
    try testing.expect(std.mem.indexOf(u8, page, "set-cookie: gopher_auth=") == null);
    try testing.expect(std.mem.indexOf(u8, page, "Names can use only") != null);
    try testing.expectEqual(@as(?[]const u8, null), try users.findMemberByName(io, a, "Bobx"));
    // Nor logs in as the member the cleaned name would have been.
    _ = try memberSession(a, io, "1", "Steve");
    const as_steve = try postForm(a, io, "/login/full", "x=y", "name=Steve%3C&password=pw&action=login");
    try testing.expect(std.mem.indexOf(u8, as_steve, "set-cookie: gopher_auth=") == null);
}

/// A POST whose handler fails: the answer it was given (route answers the
/// failure, then hands the error on to the host, to log).
fn postFailing(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body });
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    try testing.expect(std.meta.isError(route(&req, io, a, &b)));
    try out.writer.flush();
    return out.written();
}

test "route: a pin, a bookmark or the login mirror that will not write is a 500, never a quiet success (156(g))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // The pins' folder is a file: the pin cannot be written.
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "pinned-sessions" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", status(try postFailing(a, io, "/chat/c/1_2/Plans/pin", steve, "")));
    // The bookmarks' folder is a file: a send is refused before it stores.
    const bookmarks = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions" });
    try std.Io.Dir.cwd().deleteTree(io, bookmarks);
    try UidSite.disk.write(io, a, bookmarks, "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", status(try postFailing(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=hello&cid=x")));
    const raw = (try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Plans")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_store.decodeChatFile(a, raw)).len);
    // The player row is a file where its folder goes: the login's mirror fails.
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ player.player_root, "1" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", status(try postFailing(a, io, "/login/full", "x=y", "name=Steve&password=pw&action=login")));
}

test "route: one form decoder: a bad escape or a field sent twice is a 400 on every form, where chat took them and players refused them as a 500 (156(i))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    for ([_][]const u8{ "markdown=100%zz&cid=x", "markdown=a&markdown=b&cid=x", "markdown=50%&cid=x" }) |bad| {
        try testing.expectEqualStrings("400 Bad Request", status(try postAs(a, io, "/chat/c/1_2/Plans/send", steve, bad)));
    }
    const raw = (try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Plans")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_store.decodeChatFile(a, raw)).len);
    try testing.expectEqualStrings("400 Bad Request", status(try postForm(a, io, "/play", "x=y", "name=Ada%zz&next=%2Fgame")));
    // A well-formed escape still decodes.
    try testing.expectEqualStrings("303 See Other", status(try postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=100%25&cid=y")));
}

test "route: an admin delete of a player there is not says so, 404, where it went back to the roster as if done (156(i))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const me = try adminSession(a, io);
    try testing.expectEqualStrings("404 Not Found", status(try postForm(a, io, "/admin/lynrummy/delete", me, "user=p999")));
    try testing.expectEqualStrings("404 Not Found", status(try UidSite.ask(a, io, "/admin/lynrummy/delete?user=p999", me)));
    const id = try player.allocate(io, a, "Nikhil");
    try testing.expectEqualStrings("200 OK", status(try UidSite.ask(a, io, try std.fmt.allocPrint(a, "/admin/lynrummy/delete?user={s}", .{id}), me)));
}

test "route: a topic that is not there is a 404 that says so, on every tail but send, and never becomes where /chat/default resumes; a channel not the viewer's says why (156(j))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    const page = try UidSite.ask(a, io, "/chat/c/1_2/Nowhere", steve);
    try testing.expectEqualStrings("404 Not Found", status(page));
    try testing.expect(std.mem.indexOf(u8, page, "Nowhere") != null);
    for ([_][]const u8{ "/chat/c/1_2/Nowhere/raw", "/chat/c/1_2/Nowhere/stream", "/chat/c/1_2/Nowhere/reactions" }) |t|
        try testing.expectEqualStrings("404 Not Found", status(try UidSite.ask(a, io, t, steve)));
    try testing.expectEqualStrings("404 Not Found", status(try postAs(a, io, "/chat/c/1_2/Nowhere/react", steve, "msg=1&emoji=%F0%9F%91%8D")));
    try testing.expect((try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Nowhere")) == null);
    // Another case is the same topic (Steve, 2026-10-02).
    try testing.expectEqualStrings("200 OK", status(try UidSite.ask(a, io, "/chat/c/1_2/PLANS/raw", steve)));
    // The resume pointer still names Plans.
    const last = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions", "1_2" });
    try testing.expectEqualStrings("Plans\n", try UidSite.disk.read(io, a, last, .limited(64)));
    // A channel the viewer is not in: a page that says why, worded as for one that is not there.
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n", .{});
    const removed = try UidSite.ask(a, io, "/channel/quiet", steve);
    const absent = try UidSite.ask(a, io, "/channel/nothere", steve);
    try testing.expectEqualStrings("404 Not Found", status(removed));
    try testing.expectEqualStrings("404 Not Found", status(absent));
    const why = "is not a channel you are a member of";
    try testing.expect(std.mem.indexOf(u8, removed, why) != null and std.mem.indexOf(u8, absent, why) != null);
}

test "route: a send makes the topic it names, and /chat over a conversation with no topic lands on its page, never on a 404 (the review of 156(j))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const chat_state = @import("chat_state.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    // /chat, its bookmark on a conversation with no topic.
    try UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-conv" }), "1_2\n", .{});
    const landed = try UidSite.ask(a, io, "/chat/default", steve);
    try testing.expectEqualStrings("303 See Other", status(landed));
    try testing.expect(std.mem.indexOf(u8, landed, "location: /chat/c/1_2\r\n") != null);
    // A send to a topic not yet there makes it.
    try testing.expectEqualStrings("303 See Other", status(try postAs(a, io, "/chat/c/1_2/Fresh/send", steve, "markdown=first&cid=x")));
    const raw = (try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Fresh")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_store.decodeChatFile(a, raw)).len);
    _ = chat_state;
}

test "route: a GET re-signs a gopher_uid past half its life, so an active player keeps who they are; a younger one is left alone (Steve, 2026-10-10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const id = try player.allocate(io, a, "Nikhil");
    const now = nowSecs(io);
    const old = try std.fmt.allocPrint(a, "gopher_uid={s}", .{try uid_cookie.sign(a, UidSite.secret, id, now - uid_cookie.lifetime_secs / 2 - 60)});
    const renewed = try UidSite.ask(a, io, "/play", old);
    try testing.expectEqualStrings("303 See Other", status(renewed));
    const fresh = setUid(renewed) orelse return error.NoSetCookie;
    try testing.expectEqualStrings(id, uid_cookie.verify(UidSite.secret, fresh, now + uid_cookie.lifetime_secs - 3600).?);
    // A POST is never redirected: the old cookie still names them there.
    try testing.expect(playingAs(try postForm(a, io, "/play", old, ""), "Nikhil"));
    // Young: no re-sign.
    try testing.expect(setUid(try UidSite.ask(a, io, "/play", try signedUid(a, id))) == null);
}

test "route: every game write is counted as exactly what it wrote: an annotation compacted, a line trimmed, a puzzle's first move with its meta (metal-vmm QUEUE 157(b))" {
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
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/game/new-session", me, "state")));
    const Write = struct { target: []const u8, body: []const u8, files: []const []const u8 };
    const writes = [_]Write{
        .{ .target = "/game/sessions/1/annotations", .body = "{ \"a\" : 1,\n  \"b\" : \"x y\" }\n\n", .files = &.{"lynrummy-elm/sessions/1/annotations.jsonl"} },
        .{ .target = "/game/sessions/1/actions", .body = "move one\n\n\n", .files = &.{"lynrummy-elm/sessions/1/actions.dsl"} },
        .{ .target = "/puzzles/sessions/1/puzzles/0/actions", .body = "1) x\n", .files = &.{ "puzzle/sessions/1/meta", "puzzle/sessions/1/puzzle_0/actions.dsl" } },
        .{ .target = "/puzzles/sessions/1/puzzles/0/actions", .body = "2) y", .files = &.{"puzzle/sessions/1/puzzle_0/actions.dsl"} },
    };
    for (writes) |w| {
        var before: u64 = 0;
        for (w.files) |f| before += if (try UidSite.disk.statOrNull(io, a, try std.fs.path.join(a, &.{ games, f }))) |st| st.size else 0;
        const counted = limits.countedBytes(io, id) orelse 0;
        try testing.expectEqualStrings("204 No Content", status(try postAs(a, io, w.target, me, w.body)));
        var after: u64 = 0;
        for (w.files) |f| after += (try UidSite.disk.stat(io, a, try std.fs.path.join(a, &.{ games, f }))).size;
        try testing.expectEqual(after - before, limits.countedBytes(io, id).? - counted);
    }
}

test "route: the conversation page hands the client the upload caps and the accepted types, the server's own, where chat_compose.js kept copies (metal-vmm QUEUE 157(d))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_upload = @import("chat_upload.zig");
    const steve = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    const page = try UidSite.ask(a, io, "/chat/c/1_2/Plans", steve);
    try testing.expect(std.mem.indexOf(u8, page, try std.fmt.allocPrint(a, "data-upload-image-max=\"{d}\"", .{@import("limits.zig").body.upload_image})) != null);
    try testing.expect(std.mem.indexOf(u8, page, try std.fmt.allocPrint(a, "data-upload-video-max=\"{d}\"", .{@import("limits.zig").body.upload_video})) != null);
    try testing.expect(std.mem.indexOf(u8, page, "data-upload-accept=\"" ++ chat_upload.accept ++ "\"") != null);
    // Every type the server takes is in the list, and nothing else.
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, chat_upload.accept, ',');
    while (it.next()) |mime| : (n += 1) try testing.expect(chat_upload.extOf(mime) != null);
    try testing.expectEqual(chat_upload.accepted.len, n);
}

test "route: search answers each message's excerpt cut, the word marked as the index reads it, and says its own cap; the client copies neither (metal-vmm QUEUE 157(d))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const me = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    // The word inside curly quotes and a comma, after a word that holds it
    // ("layouts"): the mark is the word the tokenizer reads, which the
    // client's regex once had to guess.
    const long = "x" ** 200;
    try writeTranscript(a, io, "1_2", "ChitChat", &.{"see layouts, then \u{201C}LAYOUT\u{201D}, here " ++ long});
    const found = try UidSite.ask(a, io, "/chat/search/messages?word=layout", me);
    try testing.expect(std.mem.indexOf(u8, found, "\"before\":\"see layouts, then \u{201C}\",\"mark\":\"LAYOUT\",\"after\":\"\u{201D}, here ") != null);
    try testing.expect(std.mem.indexOf(u8, found, "x\u{2026}\"") != null); // cut, and says so
    try testing.expect(std.mem.indexOf(u8, found, "\"markdown\":") == null); // the excerpt, not the message
    const words = try UidSite.ask(a, io, "/chat/search/words?prefix=lay", me);
    try testing.expect(std.mem.indexOf(u8, words, try std.fmt.allocPrint(a, "\"most\":{d}", .{chat_search.most_words})) != null);
    // And the page carries the shortest word a search takes.
    try testing.expectEqualStrings("200 OK", status(try postAs(a, io, "/chat/c/1_2/new", me, "topic=Plans")));
    const page = try UidSite.ask(a, io, "/chat/c/1_2/Plans", me);
    try testing.expect(std.mem.indexOf(u8, page, try std.fmt.allocPrint(a, "data-search-min=\"{d}\"", .{@import("search_tokens.zig").min_len})) != null);
}

test "route: search's budget charges the excerpts it sends, not the whole messages, so big messages do not cut the list short (the review of 157)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var site = try UidSite.init(a, io);
    defer site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const me = try memberSession(a, io, "1", "Steve");
    _ = try memberSession(a, io, "2", "Debbie");
    // Thirty messages of 100 KB, each holding the word: 3 MB whole, past the
    // 2 MiB budget; their excerpts are a few KB.
    const big = "zeppelin " ++ "x" ** (100 << 10);
    var bodies: [30][]const u8 = undefined;
    for (&bodies) |*b| b.* = big;
    try writeTranscript(a, io, "1_2", "Docs", &bodies);
    const found = try UidSite.ask(a, io, "/chat/search/messages?word=zeppelin", me);
    try testing.expect(std.mem.indexOf(u8, found, "\"matched\":30") != null);
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, found, "\"mark\":\"zeppelin\""));
    try testing.expect(found.len < 64 << 10);
}
