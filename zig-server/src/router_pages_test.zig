//! router.zig's tests: the public surfaces.

const std = @import("std");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const users = @import("users.zig");
const testing = std.testing;
const harness = @import("router_harness.zig");

test "every embedded asset is kept by the browser and asked about each use: ETag, no-cache, 304 (metal-vmm QUEUE 158)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // /game and /puzzles serve their scripts to a player only.
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const me = try harness.signedUid(a, try player.allocate(io, a, .literal("Ada")));
    const paths = [_][]const u8{
        "/chat/chat.js",           "/chat/colors.js",      "/game/elm.js",
        "/game/engine.js",         "/game/engine_glue.js", "/driving/blitter.js",
        "/driving/safari.wasm",    "/chess/board.js",      "/chess/knight.wasm",
        "/chess/queens.wasm",      "/puzzles/puzzle.js",   "/puzzles/engine.js",
        "/puzzles/engine_glue.js", "/puzzles/solver.wasm", "/delivery/app.js",
        "/delivery/solver.wasm",
    };
    for (paths) |path| {
        errdefer std.debug.print("asset {s}\n", .{path});
        const first = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ path, me }));
        try testing.expectEqualStrings("200 OK", harness.status(first));
        try testing.expectEqualStrings("no-cache", harness.responseHeader(first, "cache-control") orelse "");
        const tag = harness.responseHeader(first, "etag") orelse return error.NoETag;
        try testing.expect(tag.len > 2 and tag[0] == '"' and tag[tag.len - 1] == '"');

        const again = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nIf-None-Match: {s}\r\n\r\n", .{ path, me, tag }));
        try testing.expectEqualStrings("304 Not Modified", harness.status(again));
        try testing.expectEqualStrings("", harness.responseBody(again));
        try testing.expectEqualStrings(tag, harness.responseHeader(again, "etag") orelse "");

        const other = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nIf-None-Match: \"0\"\r\n\r\n", .{ path, me }));
        try testing.expectEqualStrings("200 OK", harness.status(other));
        try testing.expectEqualStrings(harness.responseBody(first), harness.responseBody(other));
    }
}

test "every page names its scripts by their bytes, and a script asked for by its hash is never asked about again: immutable (no GET at all)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = @import("webbox").mem_meter.useForTest(std.heap.page_allocator); // a send allocates through it
    defer meter.restore();
    // A player for the games; two members and a topic between them for chat.
    const me = try harness.signedUid(a, try player.allocate(io, a, .literal("Ada")));
    const ada = try users.allocateUser(io, a, .literal("Ada"));
    try users.setUserPassword(io, a, ada, "a password for Ada");
    const bo = try users.allocateUser(io, a, .literal("Bo"));
    try users.setUserPassword(io, a, bo, "a password for Bo");
    const cookies = try std.fmt.allocPrint(a, "{s}; __Host-gopher_auth={s}", .{ me, (try users.signSessionNow(io, a, ada)).? });
    const dm = try std.fmt.allocPrint(a, "/chat/c/{s}_{s}/scripts", .{ ada, bo });
    const body = "markdown=hello";
    const sent = try harness.serve(a, io, try std.fmt.allocPrint(a, "POST {s}/send HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ dm, cookies, body.len, body }));
    try testing.expect(harness.status(sent)[0] == '2' or harness.status(sent)[0] == '3');

    const pages = [_][]const u8{
        dm,      "/chat/recent", "/chat/images", "/chat/code",    "/chat/docs",    "/chat/links",
        "/game", "/puzzles",     "/driving",     "/chess/knight", "/chess/queens", "/delivery",
    };
    for (pages) |page| {
        errdefer std.debug.print("page {s}\n", .{page});
        const got = try harness.UidSite.ask(a, io, page, cookies);
        try testing.expectEqualStrings("200 OK", harness.status(got));
        const html = harness.responseBody(got);
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
            const asked = try harness.UidSite.ask(a, io, src, cookies);
            try testing.expectEqualStrings("200 OK", harness.status(asked));
            try testing.expectEqualStrings("public, max-age=31536000, immutable", harness.responseHeader(asked, "cache-control") orelse "");
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "\"{s}\"", .{src[q + 3 ..]}), harness.responseHeader(asked, "etag") orelse "");
            // The same path with another hash: today's bytes, asked about each use.
            const stale = try harness.UidSite.ask(a, io, try std.fmt.allocPrint(a, "{s}?h=0", .{src[0..q]}), cookies);
            try testing.expectEqualStrings("200 OK", harness.status(stale));
            try testing.expectEqualStrings("no-cache", harness.responseHeader(stale, "cache-control") orelse "");
            try testing.expectEqualStrings(harness.responseBody(asked), harness.responseBody(stale));
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

    // The fallthrough. "/drivingX" must NOT reach /driving — http.pathUnder wants a
    // boundary, and this is the case that rule exists for.
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.get(a, io, "/nope")));
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.get(a, io, "/drivingX")));

    // Only "/" is the index; the notFound fallthrough catches everything else.
    // The home page reads pages/home.txt from the repo's root, and a test runs
    // in zig-server/, where it is not: so here "/" is the home handler's own
    // 500 ("Home unavailable"), never the fallthrough's 404. (It answered 200
    // with that page until a failed render became a 500, which is how this
    // test came to pass on a page that never rendered.)
    const index = try harness.get(a, io, "/");
    try testing.expect(!std.mem.eql(u8, harness.status(index), "404 Not Found"));
    try testing.expect(std.mem.indexOf(u8, index, "Home unavailable") != null or std.mem.eql(u8, harness.status(index), "200 OK"));
}

test "route: a query string never changes which arm is taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // http.pathOf's whole job: the asset URLs carry their hash, ?h= (http.hashedSrc).
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.get(a, io, "/nope?h=0")));
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.get(a, io, "/drivingX?h=0")));
}

test "route: the game surfaces send a nameless visitor to /play, not into the store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No cookie, so no player. The gate IS the contract — see puzzles.zig.
    const r = try harness.get(a, io, "/puzzles");
    try testing.expectEqualStrings("303 See Other", harness.status(r));
    try testing.expect(std.mem.indexOf(u8, r, "location: /play?next=/puzzles") != null);

    const g = try harness.get(a, io, "/game");
    try testing.expectEqualStrings("303 See Other", harness.status(g));
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
        const r = try harness.get(a, io, path);
        try testing.expectEqualStrings("303 See Other", harness.status(r));
        try testing.expect(std.mem.indexOf(u8, r, "location: /login/full") != null);
        try testing.expect(std.mem.indexOf(u8, r, "/play") == null);
    }

    // And a non-admin identity gets a 404 rather than a confirmation that the
    // page is there. (A bare gopher_uid is a guest: never an authorized member,
    // so it can never be uid 1.)
    const raw = "GET /admin HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid=1\r\n\r\n";
    const r = try harness.serve(a, io, raw);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") == null);
}

test "route: ADMIN_ONLY — a logged-in non-admin member is refused the secret-bearing screens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    // A real, AUTHORIZED member — uid 2, with a password and a valid signed
    // session — not a guest. `/admin/backup` holds every password hash and
    // the session secret, so the gate that keeps a member out of it (and out
    // of /admin/secret and /admin/apikey) is the one that matters most for a
    // secret leak (QUEUE.md item 92; the gate is admin_ui.requireAdmin, which
    // 404s a uid that is not "1"). The anonymous/guest case is above; this is
    // the member case, which a bare gopher_uid cannot stand in for.
    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});

    for ([_][]const u8{ "/admin", "/admin/backup", "/admin/secret", "/admin/retire", "/admin/apikey", "/admin/host", "/admin/log", "/admin/lynrummy", "/admin/search?key=lay" }) |path| {
        const resp = try harness.UidSite.ask(a, io, path, member);
        try testing.expect(std.mem.indexOf(u8, resp, "200 OK") == null); // never served to a member
        try testing.expect(std.mem.indexOf(u8, resp, "$2") == null); // no bcrypt hash in the body
        try testing.expect(std.mem.indexOf(u8, resp, harness.UidSite.secret) == null); // nor the session secret
    }
}
