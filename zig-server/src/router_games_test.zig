//! router.zig's tests: games and their bounds.

const std = @import("std");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const client_address = @import("webbox").client_address;
const free_space = @import("webbox").free_space;
const testing = std.testing;
const harness = @import("router_harness.zig");

// ── the game store's growth (zig-metal-unikernel QUEUE item 52) ─────────────────────

test "route: /puzzles writes nothing; a session is made by its first move" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    const id = try player.allocate(io, a, "Nikhil");
    const me = try harness.signedUid(a, id);
    const games = try std.fs.path.join(a, &.{ harness.UidSite.storage.data_root, id });

    // Loaded three times: the same session offered, and nothing on disk.
    for (0..3) |_| {
        const page = try harness.UidSite.ask(a, io, "/puzzles", me);
        try testing.expectEqualStrings("200 OK", harness.status(page));
        try testing.expect(std.mem.indexOf(u8, page, "session_id: 1\\n") != null);
    }
    try testing.expect(!try harness.UidSite.disk.has(io, a, games));

    // An id never offered makes nothing.
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.postAs(a, io, "/puzzles/sessions/5/puzzles/0/actions", me, "1) x")));
    try testing.expect(!try harness.UidSite.disk.has(io, a, games));

    // The first move makes the session, with its meta, and lands.
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/puzzles/sessions/1/puzzles/0/actions", me, "1) x")));
    const s1 = try std.fs.path.join(a, &.{ games, "puzzle", "sessions", "1" });
    const meta = try harness.UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ s1, "meta" }), .limited(1 << 20));
    try testing.expect(std.mem.startsWith(u8, meta, "created_at: "));
    try testing.expect(std.mem.indexOf(u8, meta, "\ncatalog:\n") != null);
    // A second move, from a tab offered the same id, lands in the same one.
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/puzzles/sessions/1/puzzles/0/actions", me, "2) y")));
    try testing.expectEqualStrings("1) x\n2) y\n", try harness.UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ s1, "puzzle_0", "actions.dsl" }), .limited(64)));

    // The next load offers the next session.
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/puzzles", me), "session_id: 2\\n") != null);
}

test "route: a player's games are refused, 507, past 16 MiB or 500 sessions, and all below a quarter free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const limits = harness.UidSite.game_limits;

    const id = try player.allocate(io, a, "Nikhil");
    const me = try harness.signedUid(a, id);
    const games = try std.fs.path.join(a, &.{ harness.UidSite.storage.data_root, id });

    // A game, then its folder filled to 100 bytes short of the bound.
    const made = try harness.postAs(a, io, "/game/new-session", me, "state");
    try testing.expectEqualStrings("200 OK", harness.status(made));
    limits.forgetAll(); // the filler below is written behind its back
    const meta_len = (try harness.UidSite.disk.stat(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "1", "meta" }))).size;
    const counter_len = (try harness.UidSite.disk.stat(io, a, try std.fs.path.join(a, &.{ games, "next-session-id.txt" }))).size;
    const filler = try a.alloc(u8, limits.max_bytes - meta_len - counter_len - 100);
    @memset(filler, 'x');
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ games, "filler" }), filler, .{});

    // 99 bytes and its newline: exactly to the bound. Then one byte more is refused.
    const line = "y" ** 99;
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/game/sessions/1/actions", me, line)));
    const over = try harness.postAs(a, io, "/game/sessions/1/actions", me, "z");
    try testing.expectEqualStrings("507 Insufficient Storage", harness.status(over));
    try testing.expect(std.mem.indexOf(u8, over, "16 MiB") != null);
    try testing.expectEqualStrings("507 Insufficient Storage", harness.status(try harness.postAs(a, io, "/game/new-session", me, "state")));
    try testing.expectEqualStrings("507 Insufficient Storage", harness.status(try harness.postAs(a, io, "/puzzles/sessions/1/puzzles/0/actions", me, "1) x")));
    // Nothing of the refused writes landed.
    const actions = try harness.UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "1", "actions.dsl" }), .limited(1 << 10));
    try testing.expectEqual(@as(usize, 100), actions.len);
    try testing.expect(!try harness.UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ games, "lynrummy-elm", "sessions", "2" })));
    try testing.expect(!try harness.UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ games, "puzzle" })));

    // Sessions: another player with 500 on disk may not make one more,
    // but may still play in the ones they have.
    const other = try player.allocate(io, a, "Debbie");
    const them = try harness.signedUid(a, other);
    for (1..limits.max_sessions + 1) |n| {
        try harness.UidSite.disk.write(io, a, try std.fmt.allocPrint(a, "{s}/{s}/puzzle/sessions/{d}/meta", .{ harness.UidSite.storage.data_root, other, n }), "m", .{});
    }
    const refused = try harness.postAs(a, io, "/game/new-session", them, "state");
    try testing.expectEqualStrings("507 Insufficient Storage", harness.status(refused));
    try testing.expect(std.mem.indexOf(u8, refused, "500 game sessions") != null);
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/puzzles/sessions/7/puzzles/0/actions", them, "1) x")));

    // The floor: below a quarter free, nobody's game is saved; /play still
    // names a new player (the player store is not the game store).
    const host_space = free_space.save();
    defer host_space.restore();
    free_space.reader = lowDisk;
    const third = try player.allocate(io, a, "Gus");
    const floor = try harness.postAs(a, io, "/game/new-session", try harness.signedUid(a, third), "state");
    try testing.expectEqualStrings("507 Insufficient Storage", harness.status(floor));
    try testing.expect(std.mem.indexOf(u8, floor, "low on disk") != null);
    const named = try harness.serve(a, io, "POST /play HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 21\r\n\r\nname=Ann&next=%2Fgame");
    try testing.expectEqualStrings("303 See Other", harness.status(named));
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
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const limits = harness.UidSite.game_limits;
    const host_proxy = client_address.save();
    defer host_proxy.restore();
    client_address.trusted_proxy = "10.0.0.1";

    const Name = struct {
        fn post(al: std.mem.Allocator, i: Io, peer: []const u8, xff: []const u8) ![]const u8 {
            const body = "name=Ann&next=%2Fgame";
            return harness.serveFrom(al, i, try std.fmt.allocPrint(al, "POST /play HTTP/1.1\r\nHost: x\r\n{s}Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ xff, body.len, body }), peer);
        }
    };

    // Straight from an address: five, then a 429 that says why.
    for (0..limits.players_per_hour) |_|
        try testing.expectEqualStrings("303 See Other", harness.status(try Name.post(a, io, "203.0.113.7", "")));
    const sixth = try Name.post(a, io, "203.0.113.7", "");
    try testing.expectEqualStrings("429 Too Many Requests", harness.status(sixth));
    try testing.expect(std.mem.indexOf(u8, sixth, "the last hour") != null);
    try testing.expect(harness.setUid(sixth) == null);
    // Another address is its own.
    try testing.expectEqualStrings("303 See Other", harness.status(try Name.post(a, io, "198.51.100.1", "")));
    // An X-Forwarded-For from anyone but the proxy is not believed: still 203.0.113.7.
    try testing.expectEqualStrings("429 Too Many Requests", harness.status(try Name.post(a, io, "203.0.113.7", "X-Forwarded-For: 192.0.2.50\r\n")));

    // Through the proxy: the last address it forwarded for is the one counted,
    // whatever the client put before it.
    for (0..limits.players_per_hour) |_|
        try testing.expectEqualStrings("303 See Other", harness.status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 1.2.3.4, 192.0.2.9\r\n")));
    try testing.expectEqualStrings("429 Too Many Requests", harness.status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 5.6.7.8, 192.0.2.9\r\n")));
    try testing.expectEqualStrings("303 See Other", harness.status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 192.0.2.9, 192.0.2.10\r\n")));
    // What the proxy forwards that is not an address is not believed: the
    // request counts against the proxy itself, so six different pieces of
    // garbage are one address, and the sixth is refused.
    for (0..limits.players_per_hour) |k|
        try testing.expectEqualStrings("303 See Other", harness.status(try Name.post(a, io, "10.0.0.1", try std.fmt.allocPrint(a, "X-Forwarded-For: 192.0.2.11, not-one-{d}\r\n", .{k}))));
    try testing.expectEqualStrings("429 Too Many Requests", harness.status(try Name.post(a, io, "10.0.0.1", "X-Forwarded-For: 192.0.2.11, not-one-9\r\n")));

    // Game writes: 20 MB from one address an hour, across players.
    const ids = [_][]const u8{ try player.allocate(io, a, "One"), try player.allocate(io, a, "Two") };
    const big = try a.alloc(u8, 200 * 1024);
    @memset(big, 's');
    var sent: u64 = 0;
    var refused: ?[]const u8 = null;
    var n: usize = 0;
    while (refused == null) : (n += 1) {
        const r = try harness.serveFrom(a, io, try std.fmt.allocPrint(a, "POST /game/new-session HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ try harness.signedUid(a, ids[n % 2]), big.len, big }), "203.0.113.7");
        if (std.mem.eql(u8, harness.status(r), "429 Too Many Requests")) refused = r else {
            try testing.expectEqualStrings("200 OK", harness.status(r));
            sent += big.len;
        }
    }
    try testing.expect(std.mem.indexOf(u8, refused.?, "20 MB") != null);
    try testing.expect(sent <= limits.bytes_per_hour and sent + 2 * big.len > limits.bytes_per_hour);
    // Neither player is near their own 16 MiB: it was the address.
    try testing.expect(sent / 2 < limits.max_bytes);
    // From elsewhere, the same player still saves.
    try testing.expectEqualStrings("200 OK", harness.status(try harness.serveFrom(a, io, try std.fmt.allocPrint(a, "POST /game/new-session HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 5\r\n\r\nstate", .{try harness.signedUid(a, ids[0])}), "198.51.100.1")));
}

test "route: every game write is counted as exactly what it wrote: an annotation compacted, a line trimmed, a puzzle's first move with its meta (metal-vmm QUEUE 157(b))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const limits = harness.UidSite.game_limits;
    const id = try player.allocate(io, a, "Nikhil");
    const me = try harness.signedUid(a, id);
    const games = try std.fs.path.join(a, &.{ harness.UidSite.storage.data_root, id });
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/game/new-session", me, "state")));
    const Write = struct { target: []const u8, body: []const u8, files: []const []const u8 };
    const writes = [_]Write{
        .{ .target = "/game/sessions/1/annotations", .body = "{ \"a\" : 1,\n  \"b\" : \"x y\" }\n\n", .files = &.{"lynrummy-elm/sessions/1/annotations.jsonl"} },
        .{ .target = "/game/sessions/1/actions", .body = "move one\n\n\n", .files = &.{"lynrummy-elm/sessions/1/actions.dsl"} },
        .{ .target = "/puzzles/sessions/1/puzzles/0/actions", .body = "1) x\n", .files = &.{ "puzzle/sessions/1/meta", "puzzle/sessions/1/puzzle_0/actions.dsl" } },
        .{ .target = "/puzzles/sessions/1/puzzles/0/actions", .body = "2) y", .files = &.{"puzzle/sessions/1/puzzle_0/actions.dsl"} },
    };
    for (writes) |w| {
        var before: u64 = 0;
        for (w.files) |f| before += if (try harness.UidSite.disk.statOrNull(io, a, try std.fs.path.join(a, &.{ games, f }))) |st| st.size else 0;
        const counted = limits.countedBytes(id) orelse 0;
        try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, w.target, me, w.body)));
        var after: u64 = 0;
        for (w.files) |f| after += (try harness.UidSite.disk.stat(io, a, try std.fs.path.join(a, &.{ games, f }))).size;
        try testing.expectEqual(after - before, limits.countedBytes(id).? - counted);
    }
}
