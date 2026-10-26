//! **THE ROC'S TOPIC ROUTES AGAINST THE ZIG THEY REPLACED** (roc-webbox
//! docs/ROC-CHAT.md C4, C3, O1): one scenario of requests, served the old way
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
    // C3: the landings, the first-topic shell, the page and its sidebar.
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_3" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_3" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_9" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops" },
    .{ .who = .steve, .method = "GET", .target = "/channel/quiet" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops" },
    .{ .who = .steve, .method = "GET", .target = "/channel/nothere" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/c/1_2/Plans" },
    .{ .who = .steve, .method = "HEAD", .target = "/chat/c/1_2/Other" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/plans" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup" },
    .{ .who = .steve, .method = "GET", .target = "/channel/quiet/Nothing" },
    .{ .who = .steve, .method = "GET", .target = "/chat" },
    // C3: new topics, the conversations, a message's link, /chat resumed.
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=Ideas" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=+general3%0A" },
    .{ .who = .debbie, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=ideas" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=New" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=bad_id" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=%ZZ" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=a&topic=b" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "other=x" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=Big&pad=" ++ &@as([70000]u8, @splat('x')) },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/new" },
    // Past the react form's limit, inside a message's.
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=Padded&pad=" ++ &@as([2000]u8, @splat('x')) },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/new", .body = "topic=Mine" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_3/new", .body = "topic=First" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/new", .body = "topic=Retro" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/new", .body = "topic=Hers" },
    .{ .who = .steve, .method = "POST", .target = "/channel/nothere/new", .body = "topic=X" },
    .{ .who = .steve, .method = "GET", .target = "/chat/conversations" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/conversations" },
    .{ .who = .steve, .method = "HEAD", .target = "/chat/conversations" },
    .{ .who = .steve, .method = "POST", .target = "/chat/conversations" },
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/Plans_1" },
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/Standup_1" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/msg/Standup_1" },
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/plans_1" },
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/Nowhere_1" },
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/bad" },
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/" },
    .{ .who = .steve, .method = "GET", .target = "/chat" },
    .{ .who = .steve, .method = "GET", .target = "/chat/default" },
    .{ .who = .debbie, .method = "POST", .target = "/chat/" },
    .{ .who = .ann, .method = "GET", .target = "/chat" },
    // O1: the send, stored (to a topic there, to one it makes, async with a
    // cid), refused for each reason, a method, a stranger, a channel.
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=hello+**there**" },
    .{ .who = .debbie, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "cid=c-7&markdown=hi", .extra = "X-Chat-Async: 1\r\n" },
    .{ .who = .debbie, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=sync", .extra = "X-Chat-Async: yes\r\n" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Fresh/send", .body = "markdown=first" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/plans/send", .body = "markdown=case" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_3/Begin/send", .body = "markdown=to+Ann" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=with+a+cid&cid=c-8" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=x&cid=%ZZ" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "cid=1" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=+%0A%09" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=%FF" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=%ZZ" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=a&markdown=b" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=big&pad=" ++ &@as([70000]u8, @splat('x')) },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=padded&pad=" ++ &@as([2000]u8, @splat('x')) },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/send" },
    .{ .who = .steve, .method = "PUT", .target = "/chat/c/1_2/Plans/send", .body = "markdown=x" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send/x", .body = "markdown=x" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/send/x" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_9/Plans/send", .body = "markdown=x" },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=x" },
    .{ .who = .nobody, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=x" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Standup/send", .body = "markdown=standing" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Later/send", .body = "markdown=new+one", .extra = "X-Chat-Async: 1\r\n" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/Standup/send", .body = "markdown=x" },
    .{ .who = .steve, .method = "POST", .target = "/channel/nothere/Standup/send", .body = "markdown=x" },
    // What the sends left, read back.
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Fresh" },
    .{ .who = .steve, .method = "GET", .target = "/chat/conversations" },
    .{ .who = .ann, .method = "GET", .target = "/chat" },
    .{ .who = .steve, .method = "GET", .target = "/chat" },
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
    // Where a new DM topic is announced: the highest general<N> (a tie goes
    // to the first listed; one past an i64 is no N at all).
    for ([_][]const u8{ "general", "general2", "general02", "general9223372036854775808" }) |g| try harness.writeTranscript(a, io, "1_2", g, &.{"g"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"four"});
    // A channel's general<N>: a new channel topic is not announced in it.
    try harness.writeTranscript(a, io, "channels/ops", "general1", &.{"five"});
    // Ann's bookmark names a DM she is not in: /chat is her empty one.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "users", "3", "last-conv" }), "1_2\n", .{});
    // A channel with no topics, and a DM pair with none: the first-topic shell.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "quiet.channel" }), "1\n3\n", .{});
    @import("presence.zig").forgetForTest();

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

test "a topic's reactions, react, pin and unpin (C4), and a conversation's landing, a topic's page, a new topic, the conversations, a message's link and /chat (C3) answer as the Zig they replaced did, and leave the same files" {
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
    var seen: [9]bool = @splat(false);
    for (roc.answers) |r| for ([_][]const u8{ "204 No Content", "400 Bad Request", "404 Not Found", "405 Method Not Allowed", "413 Payload Too Large", "303 See Other", "200 OK", "302 Found", "409 Conflict" }, 0..) |want, k| {
        if (std.mem.eql(u8, harness.status(r), want)) seen[k] = true;
    };
    try testing.expect(std.mem.allEqual(bool, &seen, true));
    try testing.expect(std.mem.indexOf(u8, roc.files, "\"on\":false") != null);
    // The pages were the real ones: a sidebar with a pinned topic, the shell.
    var pages: usize = 0;
    var shells: usize = 0;
    for (roc.answers) |r| {
        if (std.mem.indexOf(u8, r, "\"pinned_sessions\":[{") != null) pages += 1;
        if (std.mem.indexOf(u8, r, "chat-first-topic") != null) shells += 1;
    }
    try testing.expect(pages > 0 and shells >= 2);
    // A new topic was announced where the partner watches.
    try testing.expect(std.mem.indexOf(u8, roc.files, "New topic: [Ideas](/chat/c/1_2/Ideas)") != null);
}
