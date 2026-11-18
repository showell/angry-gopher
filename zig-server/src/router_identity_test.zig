//! router.zig's tests: gopher_uid and sessions.

const std = @import("std");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
const testing = std.testing;
const harness = @import("router_harness.zig");

// ── gopher_uid, signed (uid_cookie.zig) ──────────────────────────────────────

test "route: only the signed __Host-gopher_uid names a player: an unsigned one, or one under the bare name, names no one and is not re-signed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    const id = try player.allocate(io, a, .literal("Nikhil"));
    const signed = try uid_cookie.sign(a, harness.UidSite.secret, id, harness.readNowSecs(io) - 3600);

    // The signed cookie under its name is the player.
    const page = try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "__Host-gopher_uid={s}", .{signed}));
    try testing.expectEqualStrings("200 OK", harness.status(page));
    try testing.expect(harness.playingAs(page, "Nikhil"));

    // Unsigned, under either name, or the signed value under the bare name:
    // no one, on a GET (no redirect, no cookie) or a POST.
    for ([_][]const u8{
        try std.fmt.allocPrint(a, "gopher_uid={s}", .{id}),
        try std.fmt.allocPrint(a, "__Host-gopher_uid={s}", .{id}),
        try std.fmt.allocPrint(a, "gopher_uid={s}", .{signed}),
    }) |c| {
        const got = try harness.UidSite.ask(a, io, "/play?next=/game", c);
        try testing.expectEqualStrings("200 OK", harness.status(got));
        try testing.expect(harness.setUid(got) == null);
        try testing.expect(!harness.playingAs(got, "Nikhil"));
        const game_page = try harness.UidSite.ask(a, io, "/game", c);
        try testing.expect(std.mem.indexOf(u8, game_page, "location: /play?next=/game") != null);
        const post = try harness.serve(a, io, try std.fmt.allocPrint(a, "POST /play HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n", .{c}));
        try testing.expect(harness.setUid(post) == null); // an empty name: the form again, no player made
        try testing.expect(!harness.playingAs(post, "Nikhil")); // and the form names no one
    }
}

test "route: a guest upgrades only with a signed cookie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    // A legacy guest: an account with a name and no password.
    try users.setUserName(io, a, "7", "Gus");
    const upgrade = "Set a password to use chat";
    const post_body = "name=Gus&password=forged&action=register&next=%2F";
    const post = try std.fmt.allocPrint(a, "POST /login/full HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid=7\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ post_body.len, post_body });

    // Unsigned: the stranger form, POST or GET, and no password set; the GET
    // re-signs nothing.
    try testing.expect(std.mem.indexOf(u8, try harness.serve(a, io, post), upgrade) == null);
    const bare = try harness.UidSite.ask(a, io, "/login/full", "gopher_uid=7");
    try testing.expect(std.mem.indexOf(u8, bare, upgrade) == null);
    try testing.expect(harness.setUid(bare) == null);
    try testing.expect(!try users.isMember(io, a, "7"));

    // The signed cookie upgrades.
    const page = try harness.UidSite.ask(a, io, "/login/full", try harness.signedUid(a, "7"));
    try testing.expect(std.mem.indexOf(u8, page, upgrade) != null);
}

test "route: an unsigned gopher_uid never names a member, the agent or a stranger, and a session under the bare name gopher_auth is no one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    // A member, with a game identity under their own number.
    try users.setUserName(io, a, "1", "Steve");
    try users.setUserPassword(io, a, "1", "hunter2");
    try player.mirror(io, a, "1", "Steve");
    // The agent.
    try users.setUserName(io, a, "3", "Claude");
    try player.mirror(io, a, "3", "Claude");
    for ([_][]const u8{ "gopher_uid=1", "gopher_uid=3", "gopher_uid=p99", "gopher_uid=../1" }) |c| {
        const r = try harness.UidSite.ask(a, io, "/play", c);
        try testing.expectEqualStrings("200 OK", harness.status(r));
        try testing.expect(harness.setUid(r) == null);
        try testing.expect(!harness.playingAs(r, "Steve") and !harness.playingAs(r, "Claude"));
    }

    // A forged signature: the right shape, the wrong MAC.
    const forged = try uid_cookie.sign(a, "not the site's secret, though just as long", "1", 1_790_000_000);
    const f = try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{forged}));
    try testing.expect(!harness.playingAs(f, "Steve"));

    // The member's games follow their session.
    const session = try users.signSession(a, harness.UidSite.secret, "1", @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s)));
    const m = try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{session}));
    try testing.expect(harness.playingAs(m, "Steve"));

    // The same session under the name before `__Host-`: no one, on a GET (no
    // redirect, no cookie moved) or a POST.
    const bare = try std.fmt.allocPrint(a, "gopher_auth={s}", .{session});
    const g = try harness.UidSite.ask(a, io, "/play", bare);
    try testing.expectEqualStrings("200 OK", harness.status(g));
    try testing.expect(!harness.playingAs(g, "Steve"));
    try testing.expect(std.mem.indexOf(u8, g, "set-cookie: __Host-gopher_auth=") == null);
    try testing.expect(!harness.playingAs(try harness.postForm(a, io, "/play", bare, ""), "Steve"));
}

test "route: /play mints a signed gopher_uid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    const r = try harness.serve(a, io, "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 23\r\n\r\nname=Nikhil&next=%2Fgame");
    try testing.expectEqualStrings("303 See Other", harness.status(r));
    const v = harness.setUid(r) orelse return error.NoSetCookie;
    const id = uid_cookie.verify(harness.UidSite.secret, v, harness.readNowSecs(io)) orelse return error.Unsigned;
    try testing.expect(harness.playingAs(try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "__Host-gopher_uid={s}", .{v})), "Nikhil"));
    // Its unsigned spelling names no one, and is not re-signed.
    const bare = try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "gopher_uid={s}", .{id}));
    try testing.expectEqualStrings("200 OK", harness.status(bare));
    try testing.expect(harness.setUid(bare) == null);
    try testing.expect(!harness.playingAs(bare, "Nikhil"));
    // With no session secret, nothing is minted: no unsigned cookie instead.
    try removeSecret(a, io);
    const none = try harness.serve(a, io, "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 23\r\n\r\nname=Debbie&next=%2Fgame");
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(none));
    try testing.expect(harness.setUid(none) == null);
}

fn removeSecret(a: std.mem.Allocator, io: Io) !void {
    try harness.UidSite.disk.remove(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" }));
}

test "route: the re-sign's redirect stays on this site" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    const cases = [_][2][]const u8{
        .{ "//evil.example/x", "/" },
        .{ "/\\evil.example/x", "/" },
        .{ "http://evil.example/y", "/" },
        .{ "/play?next=/game", "/play?next=/game" },
    };
    const id = try player.allocate(io, a, .literal("Nikhil"));
    // Past half its life: due to be signed again, on every GET until it is.
    const old = try uid_cookie.sign(a, harness.UidSite.secret, id, harness.readNowSecs(io) - uid_cookie.lifetime_secs / 2 - 60);
    for (cases) |c| {
        const r = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: __Host-gopher_uid={s}\r\n\r\n", .{ c[0], old }));
        try testing.expectEqualStrings("303 See Other", harness.status(r));
        try testing.expect(std.mem.indexOf(u8, r, try std.fmt.allocPrint(a, "location: {s}\r\n", .{c[1]})) != null);
    }
}

test "route: a GET re-signs a gopher_uid past half its life, so an active player keeps who they are; a younger one is left alone (Steve, 2026-10-10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const id = try player.allocate(io, a, .literal("Nikhil"));
    const now = harness.readNowSecs(io);
    const old = try std.fmt.allocPrint(a, "__Host-gopher_uid={s}", .{try uid_cookie.sign(a, harness.UidSite.secret, id, now - uid_cookie.lifetime_secs / 2 - 60)});
    const renewed = try harness.UidSite.ask(a, io, "/play", old);
    try testing.expectEqualStrings("303 See Other", harness.status(renewed));
    const fresh = harness.setUid(renewed) orelse return error.NoSetCookie;
    try testing.expectEqualStrings(id, uid_cookie.verify(harness.UidSite.secret, fresh, now + uid_cookie.lifetime_secs - 3600).?);
    // A POST is never redirected: the old cookie still names them there.
    try testing.expect(harness.playingAs(try harness.postForm(a, io, "/play", old, ""), "Nikhil"));
    // Young: no re-sign.
    try testing.expect(harness.setUid(try harness.UidSite.ask(a, io, "/play", try harness.signedUid(a, id))) == null);
}
