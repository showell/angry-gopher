//! router.zig's tests: request edges.

const std = @import("std");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const users = @import("users.zig");
const mem_meter = @import("webbox").mem_meter;
const testing = std.testing;
const harness = @import("router_harness.zig");

// ── request edges (metal-vmm QUEUE 183) ─────────────────────────────────────
//
// **EVERY NUMBER A REQUEST CAN CARRY, AT ITS TYPE'S EDGES.** Twice a
// ReleaseSafe panic in the served kernel came from arithmetic on a number
// the client chose (v26: a forged cookie's MAC length; v28: Last-Event-ID +
// 1). Here the whole application, in Debug (every safety check a panic), is
// sent each edge in every place a request carries a number, as a signed-in
// member. A panic names its site in the stack it prints; the request it
// came from is in `.zig-cache/tmp/request_edges_current`.
//
// **IT REFUSES TO PASS ON A SITE IT DOES NOT KNOW**: every `parseInt(` in
// src/ (outside tests) is in `edge_sites`, by file and function, either
// covered by a request below or said not to be reachable from one, and why.

const edge_numbers = [_][]const u8{
    "0",                    "-1",                   "1",                    "2147483646",                        "2147483647",
    "2147483648",           "-2147483648",          "-2147483649",          "4294967295",                        "4294967296",
    "4294967297",           "9223372036854775806",  "9223372036854775807",  "9223372036854775808",               "-9223372036854775808",
    "-9223372036854775809", "18446744073709551614", "18446744073709551615", "18446744073709551616",              "123456789012345678901234567890",
    "+5",                   "-0",                   "007",                  "000000000000000000000000000000001", " 5",
    "5 ",                   "\t5",                  "",
};

const EdgeSite = struct {
    file: []const u8,
    func: []const u8,
    /// Null: a request below reaches it. Else why none can.
    unreachable_because: ?[]const u8 = null,
};

const edge_sites = [_]EdgeSite{
    .{ .file = "sse.zig", .func = "resumeAt" },
    .{ .file = "chat_upload.zig", .func = "parseRange" },
    .{ .file = "game.zig", .func = "handle" },
    .{ .file = "game.zig", .func = "sessionRoute" },
    .{ .file = "puzzles.zig", .func = "sessionRoute" },
    .{ .file = "reactions.zig", .func = "handleReact" },
    .{ .file = "markdown.zig", .func = "listMarkerAt" },
    .{ .file = "signed.zig", .func = "verify" },
    .{ .file = "signed.zig", .func = "issuedOf" },
    .{ .file = "users_session.zig", .func = "verifySessionWithSecret" },
    .{ .file = "users_session.zig", .func = "issuedOfSession" },
    .{ .file = "chat_paths.zig", .func = "atoiOr0" },
    .{ .file = "admin_secret.zig", .func = "render" },
    .{ .file = "admin_retire.zig", .func = "readForm" },
    .{ .file = "log_view.zig", .func = "parseFilter" },
    .{ .file = "script_route.zig", .func = "parse" },
    .{ .file = "admin_backup.zig", .func = "members", .unreachable_because = "reads a tar the server itself made (its tests)" },
    .{ .file = "chat.zig", .func = "highestGeneralTopic", .unreachable_because = "topic folder names on the disk" },
    .{ .file = "chat_count.zig", .func = "numberIn", .unreachable_because = "a .count file the server wrote" },
    .{ .file = "chat_count.zig", .func = "parseCount", .unreachable_because = "a .count file the server wrote" },
    .{ .file = "chat_count.zig", .func = "parseLast", .unreachable_because = "a .count file the server wrote" },
    .{ .file = "chat_retire.zig", .func = "allMembers", .unreachable_because = "folder names on the disk" },
    .{ .file = "player.zig", .func = "lessThanByID", .unreachable_because = "player ids the server allocated" },
    .{ .file = "session_meta.zig", .func = "applyMetaScalar", .unreachable_because = "a meta file the server wrote" },
    .{ .file = "storage.zig", .func = "listSessionIDs", .unreachable_because = "folder names on the disk" },
    .{ .file = "stress.zig", .func = "main", .unreachable_because = "the stress tool, not the server" },
    .{ .file = "stress.zig", .func = "chatPairKey", .unreachable_because = "the stress tool, not the server" },
    .{ .file = "timefmt.zig", .func = "at", .unreachable_because = "message dates the server stamped" },
    .{ .file = "uid_cookie.zig", .func = "isMarked", .unreachable_because = "a marker file the server wrote (182: saturating)" },
    .{ .file = "uid_cookie.zig", .func = "windowOpen", .unreachable_because = "a window file the server wrote" },
    .{ .file = "users.zig", .func = "lessThanByNumericID", .unreachable_because = "user ids the server allocated" },
    .{ .file = "users.zig", .func = "lessThanNumericID", .unreachable_because = "user ids the server allocated" },
    .{ .file = "users.zig", .func = "userUploadBytes", .unreachable_because = "an allowance file the server wrote" },
};

/// The requests, `{N}` an edge number, `{C}` the member's cookies.
const edge_requests = [_][]const u8{
    "GET /chat/c/1_2/ChitChat/stream HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nLast-Event-ID: {N}\r\n\r\n",
    "GET /chat/c/1_2/ChitChat/stream?since={N} HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "GET /chat/c/1_2/ChitChat/uploads/a.png HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nRange: bytes={N}-{N}\r\n\r\n",
    "GET /chat/c/1_2/ChitChat/uploads/a.png HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nRange: bytes={N}-\r\n\r\n",
    "GET /chat/c/1_2/ChitChat/uploads/a.png HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nRange: bytes=-{N}\r\n\r\n",
    "GET /chat/c/1_2/ChitChat/uploads/a.png HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nRange: bytes=0-{N}\r\n\r\n",
    "GET /game/{N} HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "GET /game/sessions/{N} HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "POST /puzzles/sessions/{N}/puzzles/{N}/actions HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nContent-Length: 2\r\n\r\n{}",
    "POST /puzzles/sessions/1/puzzles/{N}/actions HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nContent-Length: 2\r\n\r\n{}",
    "POST /chat/c/1_2/ChitChat/react HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nContent-Length: {L}\r\n\r\nmsg={N}&emoji=%F0%9F%91%8D&on=1",
    "POST /chat/c/1_2/ChitChat/send HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nContent-Length: {L}\r\n\r\nmarkdown={N}.%20an%20item%0A{N})%20another",
    "GET /chat/c/1_2/ChitChat HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "GET /chat/recent HTTP/1.1\r\nHost: x\r\nCookie: __Host-gopher_auth=MQ.{N}.AAAA; __Host-gopher_uid=1.{N}.AAAA\r\n\r\n",
    "GET /chat/recent HTTP/1.1\r\nHost: x\r\nCookie: __Host-gopher_auth={N}.{N}.{N}; gopher_uid={N}\r\n\r\n",
    "GET /chat/c/{N}_2/ChitChat HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "GET /chat/c/1_{N} HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "POST /admin/secret HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nContent-Length: {L}\r\n\r\npassword=pw&days={N}",
    "GET /admin/log?request={N} HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\n\r\n",
    "POST /admin/retire HTTP/1.1\r\nHost: x\r\nCookie: {C}\r\nContent-Length: {L}\r\n\r\npassword=pw&days={N}&keep={N}",
    // The script route's envelope (metal-vmm 200), by the admin's key: its
    // numbers are read before the signature is checked.
    "POST /admin/script HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {B}\r\nContent-Length: {L}\r\n\r\nshale-signature " ++ repeated("00", 64) ++ "\nshale-1 target=x sequence={N} expires=1800000000\nprint(1)\n",
    "POST /admin/script HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {B}\r\nContent-Length: {L}\r\n\r\nshale-signature " ++ repeated("00", 64) ++ "\nshale-1 target=x sequence=1 expires={N}\nprint(1)\n",
};

/// `template` with its `{N}`, `{C}`, `{B}` (the admin's API key) and `{L}`
/// (the body's length) filled.
fn edgeRequest(a: std.mem.Allocator, template: []const u8, n: []const u8, cookies: []const u8, bearer: []const u8) ![]const u8 {
    const with_n = try std.mem.replaceOwned(u8, a, template, "{N}", n);
    const with_b = try std.mem.replaceOwned(u8, a, with_n, "{B}", bearer);
    const with_c = try std.mem.replaceOwned(u8, a, with_b, "{C}", cookies);
    const body_at = (std.mem.indexOf(u8, with_c, "\r\n\r\n") orelse return with_c) + 4;
    return std.mem.replaceOwned(u8, a, with_c, "{L}", try std.fmt.allocPrint(a, "{d}", .{with_c.len - body_at}));
}

test "request edges: every number a request carries, at its type's edges, as a member, and no panic (metal-vmm QUEUE 183)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Its own meter: in router.zig it ran after the script route's tests,
    // and on the meter one of them left set (metal-vmm QUEUE 236's split).
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();

    // **EVERY SITE IS KNOWN**: read from the source as it stands, this
    // application's and the libraries' (zig-webbox's and Shale's), each
    // library's own unreachable sites its to name.
    // Every folder, read as Zig by webbox's own reading
    // (edge_sites.parseSites, Zig's tokenizer), so a site in a sub-folder
    // (Shale's script/) or after an `inline fn` is seen.
    const library_sites = @import("webbox").edge_sites;
    const Folder = struct { dir: []const u8, unreachable_sites: []const library_sites.Site };
    var listed_seen: [edge_sites.len]bool = @splat(false);
    for ([_]Folder{
        .{ .dir = "src", .unreachable_sites = &.{} },
        .{ .dir = @import("build_options").webbox_src, .unreachable_sites = &library_sites.unreachable_from_requests },
        .{ .dir = @import("build_options").shale_src, .unreachable_sites = &@import("shale").edge_sites.unreachable_from_requests },
    }) |folder| {
        var src = try Io.Dir.cwd().openDir(io, folder.dir, .{ .iterate = true });
        defer src.close(io);
        var files = try src.walk(a);
        defer files.deinit();
        while (try files.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            // A test file is no request's: its helpers are tests' too.
            if (std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
            const path = try a.dupe(u8, entry.path);
            const text = try src.readFileAllocOptions(io, path, a, .limited(4 << 20), .of(u8), 0);
            for (try library_sites.parseSites(a, text)) |parse_at| {
                const own = for (edge_sites, 0..) |s, i| {
                    if (std.mem.eql(u8, s.file, path) and std.mem.eql(u8, s.func, parse_at.func)) {
                        listed_seen[i] = true;
                        break true;
                    }
                } else false;
                // A library's own unreachable sites are its to name.
                const library = for (folder.unreachable_sites) |s| {
                    if (std.mem.eql(u8, s.file, path) and std.mem.eql(u8, s.func, parse_at.func)) break true;
                } else false;
                if (!own and !library) {
                    std.debug.print("request edges: {s}:{d}, in {s}, parses a number, and is not in edge_sites: cover it with a request, or say why none reaches it\n", .{ path, parse_at.line, parse_at.func });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    // And every entry is still a site: a stale one would excuse whatever
    // parse came to a function of its name later.
    for (edge_sites, listed_seen) |s, seen| {
        errdefer std.debug.print("request edges: edge_sites names {s}'s {s}, which parses no number now\n", .{ s.file, s.func });
        try testing.expect(seen);
    }

    // A member, a player, a topic with a message, and an upload in it.
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    const id = try player.allocate(io, a, "Steve");
    const cookies = try std.fmt.allocPrint(a, "{s}; {s}", .{ steve, try harness.signedUid(a, id) });
    const bearer = try users.setUserAPIKey(io, a, "1");
    try harness.writeTranscript(a, io, "1_2", "ChitChat", &.{"hello"});
    const chat_store = @import("chat_store.zig");
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.uploads", "a.png" }), "\x89PNG\r\n\x1a\n" ++ &@as([1000]u8, @splat('x')), .{});

    const current = ".zig-cache/tmp/request_edges_current";
    var sent: usize = 0;
    for (edge_requests) |template| for (edge_numbers) |n| {
        const raw = try edgeRequest(a, template, n, cookies, bearer);
        // Where a panic came from: the stack names the site, this the request.
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = current, .data = raw });
        _ = harness.serve(a, io, raw) catch |e| switch (e) {
            // std refuses some heads itself (a bad Content-Length, say):
            // that is an answer, not a panic.
            error.HttpHeadersInvalid, error.HttpRequestTruncated => {},
            else => return e,
        };
        sent += 1;
    };
    try testing.expectEqual(edge_requests.len * edge_numbers.len, sent);
}

/// `s` repeated `n` times, built at comptime (Zig 0.17 removed `s ** n`).
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        var a: [s.len * n]u8 = undefined;
        @setEvalBranchQuota(1000 + n);
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}
