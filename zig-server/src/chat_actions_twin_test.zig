//! **THE ROC'S TOPIC ROUTES AGAINST THE ZIG THEY REPLACED** (roc-webbox
//! docs/ROC-CHAT.md C4): one scenario of requests, served the old way
//! (chat_actions_twin.zig) on one fresh site and the Roc's on another, at
//! one fixed time; every answer and every file left must be the same.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const chat_router = @import("chat_router.zig");
const store = @import("chat_store.zig");
const Now = @import("request_time.zig").Now;
const Alloc = std.mem.Allocator;

const testing = std.testing;
const harness = @import("router_harness.zig");
const mem_meter = webbox.mem_meter;

/// One request of the scenario: as whom, and the raw method, target, body
/// and any extra header lines.
const Ask = struct { who: enum { steve, debbie, ann, nobody }, method: []const u8, target: []const u8, body: []const u8 = "", extra: []const u8 = "" };

const thumbs = "%F0%9F%91%8D";

/// Every way the four routes answer: stored, refused for each reason in
/// its order, a method each refuses, a body too big, a malformed form, a
/// topic or conversation that is not there or not the viewer's (DM and
/// channel), a stranger, case, and an `Expect` a 405 declines.
const scenario = [_]Ask{
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/reactions" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .debbie, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=2&emoji=" ++ thumbs ++ "&on=1" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=" ++ thumbs ++ "&on=0" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=" ++ thumbs ++ "&on=yes" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "emoji=" ++ thumbs ++ "&msg=2" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=9&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=0&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=x&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=%2B1&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=A" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=%F0%9F" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&msg=2&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=%ZZ" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=" ++ thumbs ++ "&pad=" ++ &@as([1100]u8, @splat('x')) },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/react" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/react" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/react", .extra = "Expect: 100-continue\r\n" },
    .{ .who = .steve, .method = "HEAD", .target = "/chat/c/1_2/Plans/reactions" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/reactions" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/reactions" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/c/1_2/plans/reactions" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/plans/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/pin" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/pin" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Other/pin" },
    .{ .who = .debbie, .method = "POST", .target = "/chat/c/1_2/Plans/pin" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Other/unpin" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/pin" },
    .{ .who = .steve, .method = "PUT", .target = "/chat/c/1_2/Plans/unpin" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Nowhere/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Nowhere/reactions" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Nowhere/pin" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_9/Plans/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/reactions" },
    .{ .who = .nobody, .method = "POST", .target = "/chat/c/1_2/Plans/pin" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Standup/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/reactions" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Standup/pin" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Standup/unpin" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/Standup/react", .body = "msg=1&emoji=" ++ thumbs },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Gone/pin" },
    .{ .who = .steve, .method = "POST", .target = "/channel/nothere/Standup/pin" },
};

/// The scenario on a fresh site, served the old way or the Roc's: every
/// answer, then every file the site holds but the members' sessions.
fn run(a: Alloc, io: Io, oracle: bool) !struct { answers: [][]const u8, files: []const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    const ann = try harness.memberSession(a, io, "3", "Ann");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    try harness.writeTranscript(a, io, "1_2", "Other", &.{"three"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"four"});

    chat_router.test_oracle = oracle;
    defer chat_router.test_oracle = false;
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;
    const answers = try a.alloc([]const u8, scenario.len);
    for (scenario, answers) |s, *got| {
        const cookie = switch (s.who) {
            .steve => steve,
            .debbie => debbie,
            .ann => ann,
            .nobody => "",
        };
        got.* = try harness.serve(a, io, try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{ s.method, s.target, cookie, s.body.len, s.extra, s.body }));
    }
    return .{ .answers = answers, .files = try tree(a, io, site.base) };
}

/// Every file under `root` but the auth tree (each site's sessions are its
/// own), as path and bytes, in order.
fn tree(a: Alloc, io: Io, root: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.indexOf(u8, e.path, "auth") != null) continue;
        try paths.append(a, try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (paths.items) |p| {
        const bytes = try dir.readFileAlloc(io, p, a, .unlimited);
        try out.writer.print("== {s}\n{s}\n", .{ p, bytes });
    }
    return out.toOwnedSlice();
}

test "a topic's reactions, react, pin and unpin answer as the Zig they replaced did, and leave the same files (C4)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const zig = try run(a, io, true);
    const roc = try run(a, io, false);
    var differ: usize = 0;
    for (scenario, zig.answers, roc.answers) |s, z, r| if (!std.mem.eql(u8, z, r)) {
        differ += 1;
        std.debug.print("{s} {s} {s}\n  zig: {f}\n  roc: {f}\n", .{ @tagName(s.who), s.method, s.target, std.zig.fmtString(z), std.zig.fmtString(r) });
    };
    if (!std.mem.eql(u8, zig.files, roc.files)) {
        differ += 1;
        std.debug.print("files differ\n  zig: {f}\n  roc: {f}\n", .{ std.zig.fmtString(zig.files), std.zig.fmtString(roc.files) });
    }
    try testing.expectEqual(@as(usize, 0), differ);
    // The scenario reached what it means to: stores, every refusal, the 404s.
    var seen: [6]bool = @splat(false);
    for (roc.answers) |r| for ([_][]const u8{ "204 No Content", "400 Bad Request", "404 Not Found", "405 Method Not Allowed", "413 Payload Too Large", "303 See Other" }, 0..) |want, k| {
        if (std.mem.eql(u8, harness.status(r), want)) seen[k] = true;
    };
    try testing.expect(std.mem.allEqual(bool, &seen, true));
    try testing.expect(std.mem.indexOf(u8, roc.files, "\"on\":false") != null);
}
