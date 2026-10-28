//! router.zig's tests: the legacy names' migration: **deleted whole the day the legacy names retire**.

const std = @import("std");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const player = @import("player.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
const testing = std.testing;
const harness = @import("router_harness.zig");

test "route: one address may have 3 legacy cookies re-signed an hour, then 429" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const limits = harness.UidSite.game_limits;

    var ids: [5][]const u8 = undefined;
    for (&ids) |*id| id.* = try player.allocate(io, a, .literal("Nikhil"));
    const from = struct {
        fn get(al: std.mem.Allocator, i: Io, id: []const u8, peer: []const u8) ![]const u8 {
            return harness.serveFrom(al, i, try std.fmt.allocPrint(al, "GET /play HTTP/1.1\r\nHost: x\r\nCookie: gopher_uid={s}\r\n\r\n", .{id}), peer);
        }
    };
    for (ids[0..limits.resigns_per_hour]) |id|
        try testing.expectEqualStrings("303 See Other", harness.status(try from.get(a, io, id, "203.0.113.7")));
    // The sweep's next id: refused, saying why, and not marked, so its owner
    // can still come back.
    const swept = try from.get(a, io, ids[3], "203.0.113.7");
    try testing.expectEqualStrings("429 Too Many Requests", harness.status(swept));
    try testing.expect(std.mem.indexOf(u8, swept, "renewed") != null);
    try testing.expect(harness.setUid(swept) == null);
    try testing.expect(!harness.UidSite.isSigned(a, io, ids[3]));
    // Its owner, from their own address, is re-signed.
    try testing.expectEqualStrings("303 See Other", harness.status(try from.get(a, io, ids[3], "198.51.100.1")));
    // And an ordinary visit from the swept-out address is untouched.
    try testing.expectEqualStrings("200 OK", harness.status(try harness.serveFrom(a, io, "GET /play HTTP/1.1\r\nHost: x\r\n\r\n", "203.0.113.7")));
}

test "route: a session under its legacy name is moved to __Host-gopher_auth by the next GET, the legacy one cleared (metal-vmm QUEUE 170.8)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    try users.setUserPassword(io, a, "2", "hunter2");
    // Signed before the move, as a real legacy session was.
    const now_s: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const before = @min(now_s, http.legacy_issued_before_unix) - 3600;
    const value = try users.signSession(a, harness.UidSite.secret, "2", before);
    const legacy = try std.fmt.allocPrint(a, "gopher_auth={s}", .{value});
    const moved = try harness.UidSite.ask(a, io, "/play", legacy);
    try testing.expectEqualStrings("303 See Other", harness.status(moved));
    try testing.expect(std.mem.indexOf(u8, moved, try std.fmt.allocPrint(a, "set-cookie: __Host-gopher_auth={s};", .{value})) != null);
    try testing.expect(std.mem.indexOf(u8, moved, "set-cookie: gopher_auth=; Path=/; Max-Age=0") != null);
    // Under the new name: nothing to move.
    try testing.expect(!std.mem.startsWith(u8, harness.status(try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{value}))), "303"));
}

test "route: a signed gopher_uid under its old name is moved to __Host-gopher_uid by the next GET, and still names its player meanwhile (metal-vmm QUEUE 167.5)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const id = try player.allocate(io, a, .literal("Nikhil"));
    const value = try uid_cookie.sign(a, harness.UidSite.secret, id, @min(harness.readNowSecs(io), http.legacy_issued_before_unix) - 3600);
    const legacy = try std.fmt.allocPrint(a, "gopher_uid={s}", .{value});
    const moved = try harness.UidSite.ask(a, io, "/play", legacy);
    try testing.expectEqualStrings("303 See Other", harness.status(moved));
    try testing.expect(harness.setUid(moved) != null);
    // The legacy one cleared in the same answer (metal-vmm QUEUE 170.8): a
    // browser that drops the new one (plain http) is a new visitor, never
    // a loop of 303s.
    try testing.expect(std.mem.indexOf(u8, moved, "set-cookie: gopher_uid=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax\r\n") != null);
    // A POST is never redirected: the old name still names them there.
    try testing.expect(harness.playingAs(try harness.postForm(a, io, "/play", legacy, ""), "Nikhil"));
    // A sibling's plant under the old name, beside the site's own new one,
    // is not read at all.
    const other = try player.allocate(io, a, .literal("Debbie"));
    const planted = try std.fmt.allocPrint(a, "gopher_uid={s}; __Host-gopher_uid={s}", .{ try uid_cookie.sign(a, harness.UidSite.secret, other, harness.readNowSecs(io)), value });
    try testing.expect(harness.playingAs(try harness.UidSite.ask(a, io, "/play", planted), "Nikhil"));
}

/// Who `users.loadCurrentUser` says a raw request is for.
fn askCurrentId(a: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    var reader: std.Io.Reader = .fixed(raw);
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var server = std.http.Server.init(&reader, &out);
    var req = try server.receiveHead();
    return (try users.loadCurrentUser(io, a, &req)).id;
}

test "route: a legacy session is read on a POST (never redirected), not read past the end date, and not read nor moved when signed after the cutoff (metal-vmm QUEUE 176.1, 176.8)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    try users.setUserPassword(io, a, "2", "hunter2");
    const before = @min(harness.readNowSecs(io), http.legacy_issued_before_unix) - 3600;
    const legacy = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", before)});
    const post = try std.fmt.allocPrint(a, "POST /play HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 0\r\n\r\n", .{legacy});
    // A POST: read under the old name, as it was meant.
    try testing.expectEqualStrings("2", try askCurrentId(a, io, post));
    try testing.expect(!std.mem.startsWith(u8, harness.status(try harness.postForm(a, io, "/play", legacy, "")), "303"));
    // Signed after the cutoff: a plant, read as no one, never moved.
    const late = try std.fmt.allocPrint(a, "gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", http.legacy_issued_before_unix + 60)});
    try testing.expectEqualStrings("", try askCurrentId(a, io, try std.fmt.allocPrint(a, "POST /play HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 0\r\n\r\n", .{late})));
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/play", late), "set-cookie: __Host-gopher_auth=") == null);
    // Past the end date: the legacy name is not read at all.
    const saved_clock = http.names_clock_for_test;
    defer http.names_clock_for_test = saved_clock;
    http.names_clock_for_test = http.legacy_names_until_unix;
    try testing.expectEqualStrings("", try askCurrentId(a, io, post));
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/play", legacy), "set-cookie: __Host-gopher_auth=") == null);
}

test "route: a legacy uid signed after the cutoff names no one and is not moved; past the end date no legacy uid is read (metal-vmm QUEUE 176.1, 176.8)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const id = try player.allocate(io, a, .literal("Nikhil"));
    const late = try std.fmt.allocPrint(a, "gopher_uid={s}", .{try uid_cookie.sign(a, harness.UidSite.secret, id, http.legacy_issued_before_unix + 60)});
    const got = try harness.UidSite.ask(a, io, "/play", late);
    try testing.expect(!harness.playingAs(got, "Nikhil"));
    try testing.expect(harness.setUid(got) == null);
    const ok = try std.fmt.allocPrint(a, "gopher_uid={s}", .{try uid_cookie.sign(a, harness.UidSite.secret, id, @min(harness.readNowSecs(io), http.legacy_issued_before_unix) - 3600)});
    const saved_clock = http.names_clock_for_test;
    defer http.names_clock_for_test = saved_clock;
    http.names_clock_for_test = http.legacy_names_until_unix;
    const ended = try harness.UidSite.ask(a, io, "/play", ok);
    try testing.expect(!harness.playingAs(ended, "Nikhil"));
    try testing.expect(harness.setUid(ended) == null);
}
