//! **THE ROC'S TOPIC ROUTES AGAINST THE ZIG THEY REPLACED** (roc-webbox
//! docs/ROC-CHAT.md C4, C3, O1, raw, links): one scenario of requests, served the Roc's
//! way at one fixed time, its answers, files, frames and searches held to
//! a hash taken while the old way (chat_actions_twin.zig, retired) agreed.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const chat_router = @import("chat_router.zig");
const store = @import("chat_store.zig");
const chat_paths = @import("chat_paths.zig");
const chat_count = @import("chat_count.zig");
const chat_fanout = @import("chat_fanout.zig");
const chat_search = @import("chat_search.zig");
const search_index = @import("search_index.zig");
const Now = @import("request_time.zig").Now;
const Alloc = std.mem.Allocator;

const testing = std.testing;
const harness = @import("router_harness.zig");
const users = @import("users.zig");
const mem_meter = webbox.mem_meter;

/// **THE ROC'S RUN, FROZEN** (metal-vmm QUEUE 263d): each scenario below
/// was served twice, the old Zig's way (chat_actions_twin.zig, retired) and
/// the Roc's, and every answer, file, frame and search held equal. The
/// Roc's run alone is now pinned as one SHA-256 of all of it, taken the day
/// the two agreed, so the hash is the old Zig's run too. A script's hashed
/// src (`?v=<hex>`) is read as `?v=*`, so an edit to a script is no
/// change of the run. A change of one byte fails; to see where, run the
/// scenario at the commit before 263d, which held it to the old Zig.
fn freezeRun(comptime what: []const u8, run_: anytype, want: []const u8) !void {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    inline for (@typeInfo(@TypeOf(run_)).@"struct".field_names) |name| {
        const v = @field(run_, name);
        stable(&h, name);
        switch (@TypeOf(v)) {
            []const u8, []u8 => stable(&h, v),
            [][]const u8, []const []const u8 => for (v) |x| stable(&h, x),
            usize => {
                var buf: [24]u8 = undefined;
                stable(&h, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
            },
            else => @compileError("freezeRun: " ++ name ++ " is no run's field"),
        }
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    const got = std.fmt.bytesToHex(d, .lower);
    if (std.mem.eql(u8, &got, want)) return;
    std.debug.print(what ++ ": the Roc's run hashes to {s}; frozen: {s}\n", .{ &got, want });
    return error.TestUnexpectedResult;
}

/// `bytes`, length-prefixed, into `h`, every `?v=` and the hex after it
/// as `?v=*`.
fn stable(h: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "?v=")) |at| {
        h.update(bytes[i .. at + 3]);
        h.update("*");
        i = at + 3;
        while (i < bytes.len and std.ascii.isHex(bytes[i])) i += 1;
    }
    h.update(bytes[i..]);
}

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
    // A topic in several channels: the first of the member's by bytes
    // (Zed before aaa before ops), never one they are not in; a member in
    // no channel (Debbie).
    .{ .who = .steve, .method = "GET", .target = "/chat/msg/Shared_1" },
    .{ .who = .ann, .method = "GET", .target = "/chat/msg/Shared_1" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/msg/Shared_1" },
    .{ .who = .ann, .method = "GET", .target = "/chat/msg/Standup_1" },
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
    // A topic's raw transcript and /chat/links.
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/raw" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Bytes/raw" },
    .{ .who = .debbie, .method = "HEAD", .target = "/chat/c/1_2/Plans/raw" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/raw" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/plans/raw" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Fresh/raw" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/raw" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/raw/x" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_9/Plans/raw" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/raw" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/raw" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/raw" },
    .{ .who = .steve, .method = "GET", .target = "/chat/links" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/links" },
    .{ .who = .steve, .method = "HEAD", .target = "/chat/links" },
    .{ .who = .steve, .method = "POST", .target = "/chat/links", .body = "x=1" },
    .{ .who = .steve, .method = "GET", .target = "/chat/links/" },
    .{ .who = .steve, .method = "GET", .target = "/chat/links/more" },
    .{ .who = .steve, .method = "GET", .target = "/chat/linksX" },
    .{ .who = .nobody, .method = "GET", .target = "/chat/links" },
    // /chat/images and /chat/code (C7): a code block sent first, to be read.
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/send", .body = "markdown=see%0A%60%60%60zig%0Aconst+x+%3D+1%3B%0A%60%60%60" },
    .{ .who = .steve, .method = "GET", .target = "/chat/images" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/images" },
    .{ .who = .steve, .method = "HEAD", .target = "/chat/images" },
    .{ .who = .steve, .method = "POST", .target = "/chat/images" },
    .{ .who = .steve, .method = "GET", .target = "/chat/images/" },
    .{ .who = .steve, .method = "GET", .target = "/chat/images/x" },
    .{ .who = .steve, .method = "GET", .target = "/chat/imagesX" },
    .{ .who = .steve, .method = "GET", .target = "/chat/code" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/code" },
    .{ .who = .steve, .method = "POST", .target = "/chat/code" },
    .{ .who = .steve, .method = "GET", .target = "/chat/code/more" },
    .{ .who = .ann, .method = "GET", .target = "/chat/code" },
    .{ .who = .nobody, .method = "GET", .target = "/chat/images" },
    // /chat/recent (C7): every topic the sends above touched, by its last
    // message, and the ones nobody wrote to by their file.
    .{ .who = .steve, .method = "GET", .target = "/chat/recent" },
    .{ .who = .debbie, .method = "GET", .target = "/chat/recent" },
    .{ .who = .ann, .method = "GET", .target = "/chat/recent" },
    .{ .who = .steve, .method = "HEAD", .target = "/chat/recent" },
    .{ .who = .steve, .method = "POST", .target = "/chat/recent" },
    .{ .who = .steve, .method = "GET", .target = "/chat/recent/" },
    .{ .who = .steve, .method = "GET", .target = "/chat/recentX" },
    // O2: the conversation found by the Roc. The DM with yourself (one
    // member, titled by your own name); keys that are not a canonical pair
    // of uids; a partner whose account has no name (titled by the id). A
    // channel whose member file is malformed is router_failures_test's.
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_1" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_1/new", .body = "topic=Me" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_1/Me" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_1/Me/send", .body = "markdown=note+to+self" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_1/Me/pin" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_1/me/reactions" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/2_1" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/01_2/Plans" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_02/Plans/raw" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/2_1/Plans/send", .body = "markdown=x" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_x/new", .body = "topic=X" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_4" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_4/Hello/send", .body = "markdown=hi+4" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_4/Hello" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_4" },
    // 271: every tail the Zig serves, by a member, by one who is not, and for
    // a topic that is not there; an invalid tail; keys that name no
    // conversation. Who answers each, and with what, is the Roc's to decide.
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/uploads/x.png" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/upload" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/download" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/saved" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/nope" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/download/x" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Plans/saved" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/uploads/x.png" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Gone/upload" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/download" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/saved" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/stream" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/nope" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Gone/download/x" },
    .{ .who = .steve, .method = "POST", .target = "/chat/c/1_2/Gone/saved" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/uploads/x.png" },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/Plans/upload" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/download" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/saved" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/stream" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/nope" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Plans/download/x" },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/Plans/saved" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Gone/uploads/x.png" },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/Gone/upload" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Gone/download" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Gone/saved" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Gone/stream" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Gone/nope" },
    .{ .who = .ann, .method = "GET", .target = "/chat/c/1_2/Gone/download/x" },
    .{ .who = .ann, .method = "POST", .target = "/chat/c/1_2/Gone/saved" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/uploads/x.png" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Standup/upload" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/download" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/saved" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/nope" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Standup/download/x" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Standup/saved" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Gone/uploads/x.png" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Gone/upload" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Gone/download" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Gone/saved" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Gone/stream" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Gone/nope" },
    .{ .who = .steve, .method = "GET", .target = "/channel/ops/Gone/download/x" },
    .{ .who = .steve, .method = "POST", .target = "/channel/ops/Gone/saved" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/uploads/x.png" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/Standup/upload" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/download" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/saved" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/stream" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/nope" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Standup/download/x" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/Standup/saved" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Gone/uploads/x.png" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/Gone/upload" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Gone/download" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Gone/saved" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Gone/stream" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Gone/nope" },
    .{ .who = .debbie, .method = "GET", .target = "/channel/ops/Gone/download/x" },
    .{ .who = .debbie, .method = "POST", .target = "/channel/ops/Gone/saved" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/2_1/Plans/download" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_9/Plans/saved" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/01_2/Plans/stream" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/bad_id/download" },
    .{ .who = .steve, .method = "GET", .target = "/channel/Bad_Name/Standup/saved" },
    .{ .who = .steve, .method = "GET", .target = "/channel/nothere/Standup/download" },
    .{ .who = .steve, .method = "GET", .target = "/channel/quiet/Nothing/saved" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/uploads/" },
    .{ .who = .steve, .method = "GET", .target = "/chat/c/1_2/Plans/uploads/../x" },
    .{ .who = .nobody, .method = "GET", .target = "/chat/c/1_2/Plans/download" },
};

/// The scenario on a fresh site, served the old way or the Roc's: every
/// answer, then every file the site holds but the members' sessions.
fn run(a: Alloc, io: Io) !struct { answers: [][]const u8, files: []const u8 } {
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
    // Channels a topic is in several of, listed in no order: Steve is in
    // Zed and ops, Ann in aaa (and quiet).
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "Zed.channel" }), "1\n", .{});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "aaa.channel" }), "3\n", .{});
    for ([_][]const u8{ "channels/Zed", "channels/aaa", "channels/ops" }) |d| try harness.writeTranscript(a, io, d, "Shared", &.{"s"});
    // An account with no name (a release cut short).
    try users.setUserPassword(io, a, "4", "pw");
    // A transcript with a byte that is not UTF-8: raw passes it untouched.
    const bytes_md = try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_2"), "sessions", "Bytes.md" });
    try harness.UidSite.disk.write(io, a, bytes_md, "caf\xe9 \xff\n", .{});
    // No message dates it, so /chat/recent dates it by its file: the same
    // second for both sites, not the clock's.
    {
        var f = try std.Io.Dir.cwd().openFile(io, bytes_md, .{ .mode = .read_write });
        defer f.close(io);
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, 1_767_225_600) * std.time.ns_per_s } } });
    }
    // Steve's feeds: more images than the page shows, a malformed block, a
    // code block, a quote, script in a tag; Debbie has none.
    {
        var im: std.ArrayList(u8) = .empty;
        for (0..25) |k| {
            if (k > 0) try im.appendSlice(a, "\n\n-------------\n\n");
            try im.print(a, "Sent by Debbie at 2026-10-0{d}T00:00:00Z, source MSG_Plans_{d} in 1_2:\n<img src=\"/u/{d}.png\" alt=\"</script>\">", .{ k % 9 + 1, k + 1, k });
        }
        try im.appendSlice(a, "\n\n-------------\n\nnot a header\n<img src=x>");
        try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "users", "1", "images.md" }), im.items, .{});
        try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "users", "1", "code.md" }), "Sent by Steve at 2026-10-01T00:00:00Z, source MSG_Standup_1 in ops:\n```py\nprint(\"hi\")\n```\n```\nplain\n```", .{});
    }
    // Steve's curated links; Debbie has none.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "users", "1", "links.md" }), "## Reading\n\n- [Zig](https://ziglang.org) & [Roc](https://www.roc-lang.org)\n- <b>bold?</b> a *point*\n", .{});
    @import("presence.zig").forgetForTest();

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
        // A topic's bundle holds its files' times, which are this run's:
        // its status and headers stand, its bytes are the bundle's own
        // tests' (chat_download.zig).
        if (std.mem.indexOf(u8, got.*, "content-type: application/gzip\r\n")) |_| got.* = try bundleShape(a, got.*);
    }
    return .{ .answers = answers, .files = try tree(a, io, site.base) };
}

/// A gzip answer as its status and headers, but its length, then `<gzip>`.
fn bundleShape(a: Alloc, answer: []const u8) ![]const u8 {
    const end = std.mem.indexOf(u8, answer, "\r\n\r\n") orelse return answer;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitSequence(u8, answer[0..end], "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) continue;
        try out.appendSlice(a, line);
        try out.appendSlice(a, "\r\n");
    }
    try out.appendSlice(a, "\r\n<gzip>");
    return out.items;
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

test "a topic's reactions, react, pin and unpin (C4), and a conversation's landing, a topic's page, a new topic, the conversations, a message's link and /chat (C3), the send (O1), raw and links answer as the Zig they replaced did, and leave the same files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const roc = try run(a, io);
    try freezeRun("run", roc, "6d7a4e52c469f785aa2cc7d10a8d9a382b100196989fabd82e26a87b127078fe");
    // The scenario reached what it means to: stores, every refusal, the 404s.
    var seen: [9]bool = @splat(false);
    for (roc.answers) |r| for ([_][]const u8{ "204 No Content", "400 Bad Request", "404 Not Found", "405 Method Not Allowed", "413 Payload Too Large", "303 See Other", "200 OK", "302 Found", "409 Conflict" }, 0..) |want, k| {
        if (std.mem.eql(u8, harness.status(r), want)) seen[k] = true;
    };
    try testing.expect(std.mem.allEqual(bool, &seen, true));
    try testing.expect(std.mem.indexOf(u8, roc.files, "\"on\":false") != null);
    // Raw was the bytes as stored, not UTF-8 and nosniff; links the curated page.
    var raws: usize = 0;
    var linked: usize = 0;
    for (roc.answers) |r| {
        if (std.mem.endsWith(u8, r, "\r\n\r\ncaf\xe9 \xff\n") and std.mem.indexOf(u8, r, "x-content-type-options: nosniff") != null) raws += 1;
        if (std.mem.indexOf(u8, r, "<a href=\"https://ziglang.org\"") != null) linked += 1;
    }
    try testing.expectEqual(@as(usize, 1), raws);
    try testing.expect(linked >= 1);
    // The feeds were the real ones: twenty images of twenty-five, the code
    // block sent above beside the stored ones.
    var feeds: usize = 0;
    for (roc.answers) |r| {
        if (std.mem.indexOf(u8, r, "\"source_id\":\"Plans_25\"") != null and std.mem.indexOf(u8, r, "\"source_id\":\"Plans_5\"") == null and std.mem.indexOf(u8, r, "\"source_id\":\"Plans_6\"") != null) feeds += 1;
        if (std.mem.indexOf(u8, r, "const x = 1;") != null and std.mem.indexOf(u8, r, "print(\\\"hi\\\")") != null) feeds += 1;
    }
    try testing.expect(feeds >= 2);
    // Recent was the real feed: the viewer's own last message as "You" on
    // one page, the same author by name on another's, an excerpt, a row
    // dated by its file.
    var yours = false;
    var named = false;
    for (roc.answers) |r| if (std.mem.indexOf(u8, r, "id=\"recent-data\"") != null) {
        if (std.mem.indexOf(u8, r, "\"who\":\"You\",\"where\":\"to Debbie\",\"topic\":\"Fresh\",\"excerpt\":\"first\"") != null) yours = true;
        if (std.mem.indexOf(u8, r, "\"who\":\"Steve\",\"where\":\"to Steve\",\"topic\":\"Fresh\"") != null and std.mem.indexOf(u8, r, "\"at\":\"2026-01-01T00:00:00Z\",\"url\":\"/chat/c/1_2/Bytes\"") != null) named = true;
    };
    try testing.expect(yours and named);
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

// ── reactions: the sidecar's bytes and the live frames, both ways ──────────

/// One request served on `hub`, the old way or the Roc's: what it answered
/// and the error the route returned, if any.
fn serveOn(a: Alloc, io: Io, hub: *webbox.bus.Hub, raw: []const u8) !struct { out: []const u8, err: ?anyerror } {
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var b = webbox.bus.Bus.of(hub);
    const err: ?anyerror = if (router.route(&req, io, a, &b)) |kept| blk: {
        if (kept) |k| webbox.bus.drop(hub, k);
        break :blk null;
    } else |e| e;
    try out.writer.flush();
    return .{ .out = out.written(), .err = err };
}

const router = @import("router.zig");

/// A react POST as `cookie`.
fn reactRaw(a: Alloc, target: []const u8, cookie: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookie, body.len, body });
}

/// Every blob published on each of `subs` (`keys` their keys), drained, as
/// `== key` then the bytes.
fn drained(a: Alloc, hub: *webbox.bus.Hub, keys: []const []const u8, subs: []const *webbox.bus.Subscriber) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (keys, subs) |k, s| {
        while (s.poll()) |blob| try out.writer.print("== {s}\n{s}", .{ k, blob });
        hub.close(s);
    }
    return out.toOwnedSlice();
}

/// Names a reaction's line must escape: a quote, a backslash, control
/// bytes, DEL, `/`, non-ASCII, two and three bytes a character; one cut of
/// its CR LF as it is read. Text only: a name is UTF-8 when it is set
/// (validateUserName), and the Roc's list_accounts! door fails a request on one
/// that is not.
const hard_names = [_][]const u8{ "Q\"uote\\back\x01ctl\x1f\ttab/sl\x7f caf\u{e9} \u{1F44D}", "Zo\u{eb} \u{2603}", "Ann\r\n" };

/// Reactions on a DM's topic and a channel's, by members named
/// `hard_names`, on sidecars that start torn (no final newline), whole, and
/// missing, the old way or the Roc's: every answer, every file the site
/// holds, and every frame each topic's key carried, in order.
fn reactRun(a: Alloc, io: Io) !struct { answers: [][]const u8, files: []const u8, frames: []const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const cookies = [_][]const u8{
        try harness.memberSession(a, io, "1", hard_names[0]),
        try harness.memberSession(a, io, "2", hard_names[1]),
        try harness.memberSession(a, io, "3", hard_names[2]),
    };
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    try harness.writeTranscript(a, io, "1_2", "Other", &.{"three"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n2\n3\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{ "four", "five", "six" });
    // A sidecar a stop cut short, one whole, and none at all (Other's).
    try harness.UidSite.disk.write(io, a, try store.reactionsPath(a, try chat_paths.dmConvDir(a, "1_2"), "Plans"), "{\"msg\":1,\"uid\":\"9\",\"fr", .{});
    try harness.UidSite.disk.write(io, a, try store.reactionsPath(a, try chat_paths.channelConvDir(a, "ops"), "Standup"), "{\"msg\":2}\n", .{});
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;

    var hub = webbox.bus.Hub.init(io, a);
    const keys = [_][]const u8{ "1_2/Plans", "1_2/Other", "ops/Standup", "1_2/plans" };
    var subs: [keys.len]*webbox.bus.Subscriber = undefined;
    for (keys, &subs) |k, *s| s.* = try hub.open(k);

    const heart = "%E2%9D%A4%EF%B8%8F";
    const Ask2 = struct { who: usize, target: []const u8, body: []const u8 };
    const asks = [_]Ask2{
        .{ .who = 0, .target = "/chat/c/1_2/Plans/react", .body = "msg=1&emoji=" ++ thumbs },
        .{ .who = 1, .target = "/chat/c/1_2/Plans/react", .body = "msg=2&emoji=" ++ heart ++ "&on=0" },
        .{ .who = 0, .target = "/chat/c/1_2/Plans/react", .body = "msg=2&emoji=" ++ thumbs ++ "&on=1" },
        .{ .who = 0, .target = "/chat/c/1_2/Plans/react", .body = "msg=3&emoji=" ++ thumbs },
        .{ .who = 0, .target = "/chat/c/1_2/Plans/react", .body = "msg=0&emoji=" ++ thumbs },
        .{ .who = 1, .target = "/chat/c/1_2/plans/react", .body = "msg=1&emoji=" ++ heart },
        .{ .who = 0, .target = "/chat/c/1_2/Other/react", .body = "msg=1&emoji=" ++ thumbs },
        .{ .who = 0, .target = "/chat/c/1_2/Other/react", .body = "msg=2&emoji=" ++ thumbs },
        .{ .who = 0, .target = "/channel/ops/Standup/react", .body = "msg=3&emoji=" ++ heart },
        .{ .who = 1, .target = "/channel/ops/Standup/react", .body = "msg=1&emoji=" ++ thumbs ++ "&on=0" },
        .{ .who = 2, .target = "/channel/ops/Standup/react", .body = "msg=2&emoji=" ++ thumbs },
        .{ .who = 2, .target = "/channel/ops/Standup/react", .body = "msg=4&emoji=" ++ thumbs },
    };
    const answers = try a.alloc([]const u8, asks.len);
    for (asks, answers) |q, *got| {
        const r = try serveOn(a, io, &hub, try reactRaw(a, q.target, cookies[q.who], q.body));
        got.* = try std.fmt.allocPrint(a, "{?t} {s}", .{ r.err, r.out });
    }
    return .{ .answers = answers, .files = try tree(a, io, site.base), .frames = try drained(a, &hub, &keys, &subs) };
}

test "a reaction stored and sent by the Roc, over append_line!, message_count! and publish!, leaves the sidecar's bytes the old Zig left and sends its frames on its keys: a torn sidecar's line kept its own, names that need escaping, every bound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const roc = try reactRun(a, io);
    try freezeRun("reactRun", roc, "0636673c02e13a082855770c7eef8b13068a9fb079386ebf58974436c474aa1a");
    // It reached what it means to: the torn line kept its own, each name
    // escaped (one as byte numbers), the stamp, both refusals, and a frame
    // for each of the eight stored, on the key of the topic as the request
    // spelled it (the old Zig's).
    for ([_][]const u8{ "\"fr\n{\"msg\":1,\"uid\":\"1\",\"from\":\"Q\\\"uote\\\\back\\u0001ctl\\u001f\\ttab/sl\x7f caf\u{e9} \u{1F44D}\"", "\"from\":\"Zo\u{eb} \u{2603}\"", "\"from\":\"Ann\"", "\"at\":\"2025-10-25T13:46:40Z\"" }) |want|
        if (std.mem.indexOf(u8, roc.files, want) == null) {
            std.debug.print("not in the files: {f}\n", .{std.zig.fmtString(want)});
            return error.TestUnexpectedResult;
        };
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, roc.frames, "event: reaction\ndata: {\"msg\":"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, roc.frames, "== 1_2/Plans\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, roc.frames, "== 1_2/plans\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, roc.frames, "== 1_2/Other\n"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, roc.frames, "== ops/Standup\n"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, try std.mem.join(a, "", roc.answers), "400 Bad Request"));
}

/// The reaction `target` as Steve, on a site where a step of it will fail,
/// the old way or the Roc's: its error, its status, the frames sent, and
/// every file the site holds.
fn failedReact(a: Alloc, io: Io, target: []const u8, comptime breaks: enum { sidecar, transcript, name }) ![]const u8 {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n2\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"four"});
    const dir = try chat_paths.dmConvDir(a, "1_2");
    switch (breaks) {
        // The sidecar a folder: its last byte cannot be read, nor appended to.
        .sidecar => try std.Io.Dir.cwd().createDirPath(io, try store.reactionsPath(a, dir, "Plans")),
        // A topic whose transcript is a link to a folder: listed, not counted.
        .transcript => {
            try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ dir, "elsewhere" }));
            try std.Io.Dir.cwd().symLink(io, "../elsewhere", try std.fs.path.join(a, &.{ dir, "sessions", "Broken.md" }), .{});
        },
        // The reactor's own name a folder: there, and unreadable.
        .name => {
            const name = try std.fs.path.join(a, &.{ users.auth_root, "1", "name" });
            try harness.UidSite.disk.remove(io, a, name);
            try std.Io.Dir.cwd().createDirPath(io, name);
        },
    }
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;
    var hub = webbox.bus.Hub.init(io, a);
    const keys = [_][]const u8{ "1_2/Plans", "1_2/Broken", "ops/Standup" };
    var subs: [keys.len]*webbox.bus.Subscriber = undefined;
    for (keys, &subs) |k, *s| s.* = try hub.open(k);
    const r = try serveOn(a, io, &hub, try reactRaw(a, target, steve, "msg=1&emoji=" ++ thumbs));
    const frames = try drained(a, &hub, &keys, &subs);
    return std.fmt.allocPrint(a, "{?t} {s}\nframes: {s}\nfiles: {s}", .{ r.err, harness.status(r.out), frames, try tree(a, io, site.base) });
}

test "a reaction whose store, count or reactor will not read fails with the old Zig's error, stores nothing and sends nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    var outs: std.ArrayList([]const u8) = .empty;
    inline for (.{
        .{ "/chat/c/1_2/Plans/react", .sidecar, "IsDir" },
        .{ "/chat/c/1_2/Broken/react", .transcript, "IsDir" },
        .{ "/channel/ops/Standup/react", .name, "IsDir" },
        .{ "/chat/c/1_2/Plans/react", .name, "IsDir" },
    }) |c| {
        const roc = try failedReact(a, io, c[0], c[1]);
        try outs.append(a, roc);
        if (!std.mem.startsWith(u8, roc, c[2] ++ " 500 Internal Server Error\nframes: \n") or std.mem.indexOf(u8, roc, "\"msg\":1,\"uid\"") != null) {
            std.debug.print("{s} ({s}):\n  roc: {f}\n", .{ c[0], @tagName(c[1]), std.zig.fmtString(roc) });
            return error.TestUnexpectedResult;
        }
    }
    try freezeRun("failedReact", .{ .answers = outs.items }, "5875d8532497189dfba6057ec3b22bedced39ce6d3156c8eeabee1a5a6ee4a87");
}

// ── sends: the transcript, the .count, every frame and search, both ways ───

/// `s` as a form value: every byte but a letter or a digit escaped.
fn formValue(a: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (std.ascii.isAlphanumeric(c)) try out.append(a, c) else try out.print(a, "%{X:0>2}", .{c});
    return out.items;
}

/// A send of `md` (with client id `cid`, when there is one) as `cookie`,
/// async (204) or not (303).
fn sendRaw(a: Alloc, target: []const u8, cookie: []const u8, md: []const u8, cid: ?[]const u8, how: enum { sync, async_ }) ![]const u8 {
    const body = try std.fmt.allocPrint(a, "markdown={s}{s}", .{ try formValue(a, md), if (cid) |c| try std.fmt.allocPrint(a, "&cid={s}", .{try formValue(a, c)}) else "" });
    return std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ target, cookie, if (how == .async_) "X-Chat-Async: 1\r\n" else "", body.len, body });
}

fn getRaw(a: Alloc, target: []const u8, cookie: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ target, cookie });
}

/// Every key a send publishes on in `sendRun`'s site: each topic's, then
/// each member's notify, sidebar, recent, images and code.
const send_keys = [_][]const u8{ "1_2/Plans", "1_2/Fresh", "ops/Standup", "ops/Brand", "1_3/Fresh", "1_1/Notes", "1_2/Feeds", "1_4/Ideas" } ++ memberKeys("1") ++ memberKeys("2") ++ memberKeys("3") ++ memberKeys("4");

/// A message for the feeds: image tags (one across a line, one whose alt
/// needs JSON's escapes, one with no space after `<img`, never a tag), and
/// fences (a longer one holding a shorter, a quote skipped, a language, one
/// never closed).
const feeds_md = "two <img src=\"/a.png\" alt=\"q\\\"x\"> and <IMG\nsrc=\"/b.png\">, not <imgx>\n\n````zig\nconst x = 1;\n```\ninner\n```\n````\n\n~~~ quote\nquoted\n~~~\n\n```c\nint y;\n```\n\n```\nunterminated\nunclosed";

fn memberKeys(comptime uid: []const u8) [5][]const u8 {
    return .{ "ntf:" ++ uid, "sb:" ++ uid, "rec:" ++ uid, "img:" ++ uid, "code:" ++ uid };
}

/// Sends on one hub, the old way (appendMessage) or the Roc's (`appended!`
/// over store_message!, publish! and fan_out!): a DM topic whose `.count`
/// is stale, topics' first messages (index 0, the sidebar's topic-added) in
/// a DM and a channel, markdown the stored form must escape (lines that
/// read as the separator, bare and escaped; the separator itself; a
/// leading `>`; CRLF; empty lines; a trailing newline), an image and a code
/// block for the feeds, names and cids JSON must escape. The search index is built before the sends, so what it finds
/// after is what the sends told it. Every answer, every file, every frame
/// on every key, and the searches.
fn sendRun(a: Alloc, io: Io) !struct { answers: [][]const u8, files: []const u8, frames: []const u8, searches: []const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const cookies = [_][]const u8{
        try harness.memberSession(a, io, "1", hard_names[0]),
        try harness.memberSession(a, io, "2", hard_names[1]),
        try harness.memberSession(a, io, "3", hard_names[2]),
    };
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    // **A STALE `.count`**: a size the transcript is not, so the count is
    // recounted (2), never believed (5).
    try harness.UidSite.disk.write(io, a, try chat_count.countPath(a, try chat_paths.dmConvDir(a, "1_2"), "Plans"), "5 9999\n40 9\n", .{});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n2\n3\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"four"});
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;

    var hub = webbox.bus.Hub.init(io, a);
    var subs: [send_keys.len]*webbox.bus.Subscriber = undefined;
    for (send_keys, &subs) |k, *s| s.* = try hub.open(k);

    // The index built now, from the disk, before any send.
    _ = try serveOn(a, io, &hub, try getRaw(a, "/chat/search/words?prefix=zz", cookies[0]));

    // Who (an index into `cookies`), where, what, its cid, and whether async.
    const sends = [_]struct { usize, []const u8, []const u8, ?[]const u8, bool }{
        .{ 0, "/chat/c/1_2/Plans/send", "-------------\n\\-------------\n\\\\-------------\n> a quote\r\nCRLF then\n\nafter an empty line\n", "c\"1\\x\x01/", false },
        .{ 1, "/chat/c/1_2/Plans/send", "a\n\n-------------\nb", null, true },
        .{ 0, "/chat/c/1_2/Fresh/send", "> zeppelin\n\n<img src=\"/u/1.png\">\n\n```zig\nconst x = 1;\n```\n", "c-2", false },
        .{ 2, "/channel/ops/Standup/send", "-------------", "</script>", false },
        .{ 1, "/channel/ops/Brand/send", "plain zeppelin words", null, true },
        .{ 0, "/channel/ops/Standup/send", "x\r\n\r\n", "\xe2\x80\xa8", false },
        .{ 2, "/chat/c/1_3/Fresh/send", "hi zeppelin", null, false },
        // The feeds: several image tags (one across a line, one whose alt
        // needs escaping), fences (a longer one holding a shorter, a quote
        // skipped, a language, one never closed), in a DM's new topic (the
        // sidebar's too), a channel of three, and the DM with yourself.
        .{ 0, "/chat/c/1_2/Feeds/send", feeds_md, null, false },
        .{ 1, "/channel/ops/Standup/send", "<img src=\"/c.png\">\n\n```sh\nls \"q\" \\\\\n```\n~~~\ntilde\n~~~", null, false },
        .{ 0, "/chat/c/1_1/Notes/send", "<img src=\"/n.png\">\n\n```\nnote\n```", null, false },
    };
    const answers = try a.alloc([]const u8, sends.len + 1);
    for (sends, answers[0..sends.len]) |s, *got| {
        const r = try serveOn(a, io, &hub, try sendRaw(a, s[1], cookies[s[0]], s[2], s[3], if (s[4]) .async_ else .sync));
        got.* = try std.fmt.allocPrint(a, "{?t} {s}", .{ r.err, r.out });
    }
    // What search finds after, for each member: words in the sends only,
    // and in a transcript from before.
    var searches: std.ArrayList(u8) = .empty;
    for (cookies) |c| for ([_][]const u8{ "zeppelin", "quote", "after", "crlf", "four", "script" }) |word| {
        chat_search.forgetAll();
        const r = try serveOn(a, io, &hub, try getRaw(a, try std.fmt.allocPrint(a, "/chat/search/messages?word={s}", .{word}), c));
        try searches.print(a, "{?t} {s}\n", .{ r.err, r.out });
    };
    // **A NAME THAT WILL NOT READ LABELS NO ROW** (recentWhere's
    // absent-ok), last, as search's roster would fail on it: member 4's name is a folder, which a new topic never
    // reads, so its "hi" fans out with member 1's Recent row named for no
    // one, and is sent all the same.
    _ = try harness.memberSession(a, io, "4", "Dee");
    const name4 = try std.fs.path.join(a, &.{ users.auth_root, "4", "name" });
    try harness.UidSite.disk.remove(io, a, name4);
    try std.Io.Dir.cwd().createDirPath(io, name4);
    const made = try serveOn(a, io, &hub, try reactRaw(a, "/chat/c/1_4/new", cookies[0], "topic=Ideas"));
    answers[sends.len] = try std.fmt.allocPrint(a, "{?t} {s}", .{ made.err, made.out });
    return .{ .answers = answers, .files = try tree(a, io, site.base), .frames = try drained(a, &hub, &send_keys, &subs), .searches = searches.items };
}

test "a message stored and sent by the Roc (C8a: its author, count, id, stamp, block and frame; store_message!, publish!, then the Zig's fan_out!) leaves the transcripts, the .count files and the feeds the old Zig left, sends the same frames on every key, and search finds the same" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence and the index outlive the request
    defer meter.restore();
    const roc = try sendRun(a, io);
    try freezeRun("sendRun", roc, "95b2465ce07a522a65f2ebefe78a5917084bede0a1777382a0d2362824207bd0");
    // It reached what it means to: every send stored (303s and 204s); the
    // stale count recounted (Plans_3, not Plans_6); the separator lines
    // escaped; a first message's topic-added on both DM members' sidebars
    // and every channel member's; the frames with their escaped names and
    // cids; the feeds; search finding what landed after it was built.
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, try std.mem.join(a, "", roc.answers), "303 See Other"));
    // The feeds (C8b): each member's images.md and code.md as the Zig wrote
    // them (a tag one line, a longer fence holding a shorter, the quote
    // skipped, the fence never closed closed), the DM with yourself one
    // entry each, not two; every member of the channel's.
    for ([_][]const u8{
        "<IMG src=\"/b.png\">",
        "```zig\nconst x = 1;\n```\ninner\n```\n```\n\n```c\nint y;\n```\n\n```\nunterminated\nunclosed\n```",
        "```sh\nls \"q\" \\\\\n```\n\n```\ntilde\n```",
    }) |want| if (std.mem.indexOf(u8, roc.files, want) == null) {
        std.debug.print("not in the files: {f}\n", .{std.zig.fmtString(want)});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, roc.files, "source MSG_Notes_1 in 1_1:"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, roc.files, "source MSG_Standup_4 in ops:"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, roc.files, "source MSG_Feeds_1 in 1_2:"));
    // The live images event rebuilds each stored tag by the renderer's rule
    // (metal-vmm QUEUE 266): `alt="q\"x"` doesn't parse (the `\"` closes it,
    // and `x"` is no attribute), so that tag is dropped whole; the other is
    // rebuilt, lower case, on one line. The files above keep the tags as sent.
    for ([_][]const u8{ "\"url\":\"/chat/c/1_4/Ideas\",\"who\":\"You\",\"topic\":\"Ideas\"", "\"where\":\"to \",\"topic\":\"Notes\"", "\"kind\":\"topic-added\",\"conv\":\"1_1\",\"sid\":\"Notes\"", "\"images\":[\"<img src=\\\"/b.png\\\">\"]" }) |want|
        if (std.mem.indexOf(u8, roc.frames, want) == null) {
            std.debug.print("not in the frames: {f}\n", .{std.zig.fmtString(want)});
            return error.TestUnexpectedResult;
        };
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, try std.mem.join(a, "", roc.answers), "204 No Content"));
    for ([_][]const u8{
        "MSG_Plans_3\nfrom: Q\"uote",
        "\\-------------\n\\\\-------------\n\\\\\\-------------\n> a quote\r\nCRLF then\n\nafter an empty line\n",
        "MSG_Plans_4\nfrom: Zo\u{eb} \u{2603}\ndate: 2025-10-25T13:46:40Z\nuid: 2\n\na\n\n\\-------------\nb",
        "sessions/Fresh.md\nMSG_Fresh_1\n",
        "sessions/Brand.md\nMSG_Brand_1\n",
        "sessions/Plans.count\n4 ",
        "MSG_Standup_2\nfrom: Ann\ndate: 2025-10-25T13:46:40Z\nuid: 3\n\n\\-------------",
    }) |want| if (std.mem.indexOf(u8, roc.files, want) == null) {
        std.debug.print("not in the files: {f}\n", .{std.zig.fmtString(want)});
        return error.TestUnexpectedResult;
    };
    for ([_][]const u8{
        "== 1_2/Plans\nid: 2\ndata: {\"index\":2,\"from\":\"Q\\\"uote\\\\back\\u0001ctl\\u001f\\ttab/sl\x7f caf\u{e9} \u{1F44D}\",\"from_uid\":\"1\",\"at\":\"2025-10-25T13:46:40Z\",\"html\":",
        ",\"id\":\"Plans_3\",\"cid\":\"c\\\"1\\\\x\\u0001/\"}\n\n",
        "id: 3\ndata: {\"index\":3,\"from\":\"Zo\u{eb} \u{2603}\",\"from_uid\":\"2\"",
        "== 1_2/Fresh\nid: 0\ndata: {\"index\":0,",
        "\"cid\":\"</script>\"}",
        "\"kind\":\"topic-added\",\"conv\":\"1_2\",\"sid\":\"Fresh\"",
        "\"kind\":\"topic-added\",\"conv\":\"ops\",\"sid\":\"Brand\"",
    }) |want| if (std.mem.indexOf(u8, roc.frames, want) == null) {
        std.debug.print("not in the frames: {f}\n", .{std.zig.fmtString(want)});
        return error.TestUnexpectedResult;
    };
    for ([_][]const u8{ "== sb:1\n", "== sb:2\n", "== sb:3\n", "== img:1\n", "== code:2\n", "== rec:3\n", "== ntf:2\n" }) |key|
        if (std.mem.indexOf(u8, roc.frames, key) == null) {
            std.debug.print("nothing published on {s}\n", .{key});
            return error.TestUnexpectedResult;
        };
    try testing.expect(std.mem.indexOf(u8, roc.searches, "\"id\":\"Brand_1\"") != null and std.mem.indexOf(u8, roc.searches, "\"id\":\"Fresh_1\"") != null);
}

/// A send as Steve to `target`, on a site where a step of it will fail, the
/// old way or the Roc's: its error, its status, every frame sent on every
/// Every key a docs' post publishes on in `docsRun`'s site.
const docs_keys = [_][]const u8{ "1_2/Plans", "1_2/Other", "1_3/2025-10-25" } ++ memberKeys("1") ++ memberKeys("2") ++ memberKeys("3");

/// A docs' post (POST /chat/docs/post, metal-vmm QUEUE 278) as `cookie`.
fn postRaw(a: Alloc, cookie: []const u8, target: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookie, body.len, body });
}

/// Docs posted to the member's default partner: to the topic they last
/// viewed, to the first of a DM's topics, to a new one named for the day;
/// a slug spaced, empty, missing, not a slug, two of them, a form that will
/// not decode; an empty doc and one not there; a GET, a stranger, a path
/// past `post`; and last, a member with no partner left to post to. Every
/// answer, every file, every frame on every key.
fn docsRun(a: Alloc, io: Io) !struct { answers: [][]const u8, files: []const u8, frames: []const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    const ann = try harness.memberSession(a, io, "3", "Ann");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    try harness.writeTranscript(a, io, "1_2", "Other", &.{"three"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "users", "1", "last-sessions", "1_2" }), "Plans\n", .{});
    for ([_][3][]const u8{
        .{ "1", "notes", feeds_md },
        .{ "1", "blank", " \t\r\n" },
        .{ "2", "hello", "hi -------------\n-------------\nsteve" },
        .{ "3", "ann", "from ann" },
    }) |d| try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "users", d[0], "docs", try std.fmt.allocPrint(a, "{s}.md", .{d[1]}) }), d[2], .{});
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;

    var hub = webbox.bus.Hub.init(io, a);
    var subs: [docs_keys.len]*webbox.bus.Subscriber = undefined;
    for (docs_keys, &subs) |k, *s| s.* = try hub.open(k);

    const posts = [_]struct { []const u8, []const u8, []const u8 }{
        .{ steve, "/chat/docs/post", "slug=notes" },
        .{ steve, "/chat/docs/post", "slug=+notes%0D%0A" },
        .{ steve, "/chat/docs/post", "slug=blank" },
        .{ steve, "/chat/docs/post", "slug=gone" },
        .{ steve, "/chat/docs/post", "slug=Bad_Slug" },
        .{ steve, "/chat/docs/post", "" },
        .{ steve, "/chat/docs/post", "slug=%ZZ" },
        .{ steve, "/chat/docs/post", "slug=notes&slug=blank" },
        .{ steve, "/chat/docs/post", "other=1&slug=notes" },
        .{ steve, "/chat/docs/post/", "slug=notes" },
        .{ debbie, "/chat/docs/post", "slug=hello" },
        .{ ann, "/chat/docs/post", "slug=ann" },
        .{ "", "/chat/docs/post", "slug=notes" },
    };
    var answers: std.ArrayList([]const u8) = .empty;
    for (posts) |p| {
        const r = try serveOn(a, io, &hub, try postRaw(a, p[0], p[1], p[2]));
        try answers.append(a, try std.fmt.allocPrint(a, "{?t} {s}", .{ r.err, r.out }));
    }
    const got = try serveOn(a, io, &hub, try getRaw(a, "/chat/docs/post", steve));
    try answers.append(a, try std.fmt.allocPrint(a, "{?t} {s}", .{ got.err, got.out }));
    // Debbie a guest now: Steve has no partner to post to.
    try harness.UidSite.disk.remove(io, a, try std.fs.path.join(a, &.{ users.auth_root, "2", "password" }));
    const none = try serveOn(a, io, &hub, try postRaw(a, steve, "/chat/docs/post", "slug=notes"));
    try answers.append(a, try std.fmt.allocPrint(a, "{?t} {s}", .{ none.err, none.out }));
    return .{ .answers = answers.items, .files = try tree(a, io, site.base), .frames = try drained(a, &hub, &docs_keys, &subs) };
}

test "a doc posted to chat (metal-vmm QUEUE 278): the partner, the topic it resumes, every refusal, and the transcript, the .count files, the feeds and the frames it leaves, as the old Zig's docsPost left them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    try freezeRun("docsRun", try docsRun(a, io), "1946b7c80088e0fb7def4c23585284bf1ab1e1f2a50b24144c7c2893ae85f315");
}

/// Every key the welcome DM (metal-vmm QUEUE 279) publishes on in
/// `welcomeRun`'s site: its topic, then each member's notify, sidebar,
/// recent, images and code.
const welcome_keys = [_][]const u8{ "1_3/general", "1_2/Plans" } ++ memberKeys("1") ++ memberKeys("2") ++ memberKeys("3");

/// `bytes` with every RFC 3339 stamp (`2026-10-10T00:00:00Z`) as `<at>`:
/// the old welcome was stamped by the clock, not the request's time.
fn unstamped(a: Alloc, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const t = bytes[i..];
        if (t.len >= 20 and t[4] == '-' and t[7] == '-' and t[10] == 'T' and t[13] == ':' and t[16] == ':' and t[19] == 'Z' and std.ascii.isDigit(t[0]) and std.ascii.isDigit(t[18])) {
            try out.appendSlice(a, "<at>");
            i += 20;
        } else {
            try out.append(a, t[0]);
            i += 1;
        }
    }
    return out.items;
}

/// A member signs up (Ann, by the login form), then opens /chat twice;
/// Debbie, who has a DM with the host, and the host himself open it too.
/// Where the welcome DM was seeded (login's, or the first /chat visit's),
/// what it left is the same: the transcript, the .count, the feeds, the
/// bookmark, every frame, every answer. Stamps read as `<at>`.
fn welcomeRun(a: Alloc, io: Io) !struct { answers: [][]const u8, files: []const u8, frames: []const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{"one"});
    // The next account made is 3.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, "next-id.txt" }), "3\n", .{});
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;

    var hub = webbox.bus.Hub.init(io, a);
    var subs: [welcome_keys.len]*webbox.bus.Subscriber = undefined;
    for (welcome_keys, &subs) |k, *s| s.* = try hub.open(k);

    var answers: std.ArrayList([]const u8) = .empty;
    const body = "name=Ann&password=pw&action=register";
    const signup = try serveOn(a, io, &hub, try std.fmt.allocPrint(a, "POST /login/full HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }));
    try answers.append(a, harness.status(signup.out));
    // Ann's session, as the signup's cookie signs it.
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const ann = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "3", now)});
    for ([_][]const u8{ ann, ann, debbie, steve }) |who| {
        const r = try serveOn(a, io, &hub, try getRaw(a, "/chat", who));
        try answers.append(a, try unstamped(a, try std.fmt.allocPrint(a, "{?t} {s}", .{ r.err, r.out })));
    }
    return .{ .answers = answers.items, .files = try unstamped(a, try tree(a, io, site.base)), .frames = try unstamped(a, try drained(a, &hub, &welcome_keys, &subs)) };
}

test "the welcome DM (metal-vmm QUEUE 279): a new member's, made once, from the host, by name, in general, the member's bookmark at it; one who has the DM, and the host, see no change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    try freezeRun("welcomeRun", try welcomeRun(a, io), "fdedb2107f1f87be8a530f9a8ec778c212cb628d1dba59b0abf8924819e7cb23");
}

/// GET /chat/search/words (metal-vmm QUEUE 281) over one built index, as
/// three members who see different conversations: prefixes as typed (cased,
/// spaced, punctuated, empty, missing, not UTF-8, longer than a word, two
/// of them), a word no message holds, one only a DM the asker is not in
/// holds; then a method it refuses, a path past it, and the sixth search in
/// one second. Every answer.
fn wordsRun(a: Alloc, io: Io) !struct { answers: [][]const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    const ann = try harness.memberSession(a, io, "3", "Ann");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "the layout is lazy", "Lamp, layout; \u{201C}latte\u{201D}", "la la land" });
    try harness.writeTranscript(a, io, "2_3", "Secret", &.{"laser lasers"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n3\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{ "large latte", "caf\u{00E9} CAF\u{00C9}" });
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_2"), "sessions", "Bytes.md" }), "MSG_Bytes_1\nfrom: Someone\ndate: 2026-10-10T00:00:00Z\n\nla\xffzy lab\xc3", .{});
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;
    var hub = webbox.bus.Hub.init(io, a);
    const long = "l" ++ &@as([300]u8, @splat('a'));
    const asks = [_]struct { []const u8, []const u8, []const u8 }{
        .{ steve, "GET", "/chat/search/words?prefix=la" },
        .{ steve, "GET", "/chat/search/words?prefix=LA" },
        .{ steve, "GET", "/chat/search/words?prefix=+%22La%22+" },
        .{ steve, "GET", "/chat/search/words?prefix=la&prefix=x" },
        .{ steve, "GET", "/chat/search/words?prefix=" },
        .{ steve, "GET", "/chat/search/words" },
        .{ steve, "GET", "/chat/search/words?prefix=%FF" },
        .{ steve, "GET", "/chat/search/words?prefix=la%FF" },
        .{ steve, "GET", "/chat/search/words?prefix=caf%C3%A9" },
        .{ steve, "GET", "/chat/search/words?prefix=%E2%80%9Cla" },
        .{ steve, "GET", "/chat/search/words?prefix=%ZZ" },
        .{ steve, "GET", "/chat/search/words?prefix=" ++ long },
        .{ steve, "GET", "/chat/search/words?prefix=zz" },
        .{ steve, "GET", "/chat/search/words?prefix=las" },
        .{ debbie, "GET", "/chat/search/words?prefix=la" },
        .{ ann, "GET", "/chat/search/words?prefix=la" },
        .{ steve, "POST", "/chat/search/words?prefix=la" },
        .{ steve, "HEAD", "/chat/search/words?prefix=la" },
        .{ steve, "GET", "/chat/search/words/?prefix=la" },
        .{ steve, "GET", "/chat/search/wordsX?prefix=la" },
        .{ "", "GET", "/chat/search/words?prefix=la" },
    };
    var answers: std.ArrayList([]const u8) = .empty;
    for (asks) |q| {
        chat_search.forgetAll();
        const r = try serveOn(a, io, &hub, try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 0\r\n\r\n", .{ q[1], q[2], q[0] }));
        try answers.append(a, try std.fmt.allocPrint(a, "{?t} {s}", .{ r.err, r.out }));
    }
    // The sixth in one second is refused.
    chat_search.forgetAll();
    for (0..6) |_| {
        const r = try serveOn(a, io, &hub, try getRaw(a, "/chat/search/words?prefix=la", ann));
        try answers.append(a, try std.fmt.allocPrint(a, "{?t} {s}", .{ r.err, r.out }));
    }
    return .{ .answers = answers.items };
}

test "search's words (metal-vmm QUEUE 281): each prefix as typed, over what each member sees, every refusal and the rate limit, as the old Zig answered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    try freezeRun("wordsRun", try wordsRun(a, io), "960f33ab4676af6a70d56f4409852d5056841c9d4b8e503621c4555dcd7fba62");
}

/// key, and every file the site holds.
fn failedSend(a: Alloc, io: Io, target: []const u8, comptime breaks: enum { append, count, author }) ![]const u8 {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", if (breaks == .author) "" else "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n2\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"four"});
    switch (breaks) {
        // The channel's sessions a file: the count reads nothing there (0),
        // and the append cannot make the folder.
        .append => {
            const sessions = try std.fs.path.join(a, &.{ try chat_paths.channelConvDir(a, "ops"), "sessions" });
            try std.Io.Dir.cwd().deleteTree(io, sessions);
            try harness.UidSite.disk.write(io, a, sessions, "not a folder", .{});
        },
        // A topic whose transcript is a link to a folder: not counted.
        .count => {
            const dir = try chat_paths.dmConvDir(a, "1_2");
            try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ dir, "elsewhere" }));
            try std.Io.Dir.cwd().symLink(io, "../elsewhere", try std.fs.path.join(a, &.{ dir, "sessions", "Broken.md" }), .{});
        },
        // The sender's name is empty: no author.
        .author => {},
    }
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;
    var hub = webbox.bus.Hub.init(io, a);
    const keys = [_][]const u8{ "1_2/Plans", "1_2/Broken", "ops/Standup" } ++ memberKeys("1") ++ memberKeys("2");
    var subs: [keys.len]*webbox.bus.Subscriber = undefined;
    for (keys, &subs) |k, *s| s.* = try hub.open(k);
    const r = try serveOn(a, io, &hub, try sendRaw(a, target, steve, "hello there", "c-1", .sync));
    const frames = try drained(a, &hub, &keys, &subs);
    return std.fmt.allocPrint(a, "{?t} {s}\nframes: {s}\nfiles: {s}", .{ r.err, harness.status(r.out), frames, try tree(a, io, site.base) });
}

test "a send whose transcript will not append, whose count fails, or whose sender has no name fails with the old Zig's error, stores nothing and sends nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    var outs: std.ArrayList([]const u8) = .empty;
    inline for (.{
        .{ "/channel/ops/Standup/send", .append, "NotDir" },
        .{ "/chat/c/1_2/Broken/send", .count, "IsDir" },
        .{ "/chat/c/1_2/Plans/send", .author, "NoAuthor" },
    }) |c| {
        const roc = try failedSend(a, io, c[0], c[1]);
        try outs.append(a, roc);
        // Presence's frames (the sender came online) go out before the
        // send; nothing of the message, on any key or in any file.
        if (!std.mem.startsWith(u8, roc, c[2] ++ " 500 Internal Server Error\nframes: ") or std.mem.indexOf(u8, roc, "hello") != null or std.mem.indexOf(u8, roc, "== 1_2/Plans\n") != null or std.mem.indexOf(u8, roc, "== 1_2/Broken\n") != null or std.mem.indexOf(u8, roc, "== ops/Standup\n") != null) {
            std.debug.print("{s} ({s}):\n  roc: {f}\n", .{ c[0], @tagName(c[1]), std.zig.fmtString(roc) });
            return error.TestUnexpectedResult;
        }
    }
    try freezeRun("failedSend", .{ .answers = outs.items }, "99a076713c2b16eb737290168cd3fe903ad1754987f653075baff7cf85ad8009");
}

/// Sends carrying an image and code, in DM 1_2 and channel ops (1, 2, 3),
/// on a site where member 2's images.md is a folder, the old way or the
/// Roc's: every answer, frame and file, how many fan-out failures were
/// counted, and the last one said, as /admin/host says it.
fn feedFailRun(a: Alloc, io: Io) !struct { answers: []const u8, frames: []const u8, files: []const u8, counted: usize, last: []const u8 } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Ann");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{"one"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ store.chat_root, "channels", "ops.channel" }), "1\n2\n3\n", .{});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"four"});
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ store.chat_root, "users", "2", "images.md" }));
    @import("presence.zig").forgetForTest();
    chat_router.test_now = Now.at(1_761_400_000);
    defer chat_router.test_now = null;
    var hub = webbox.bus.Hub.init(io, a);
    const keys = [_][]const u8{ "1_2/Plans", "ops/Standup" } ++ memberKeys("1") ++ memberKeys("2") ++ memberKeys("3");
    var subs: [keys.len]*webbox.bus.Subscriber = undefined;
    for (keys, &subs) |k, *s| s.* = try hub.open(k);
    const before = chat_fanout.fanout_failures;
    var answers: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "/chat/c/1_2/Plans/send", "/channel/ops/Standup/send" }) |target| {
        const r = try serveOn(a, io, &hub, try sendRaw(a, target, steve, "<img src=\"/x.png\">\n\n```\ncode\n```", null, .sync));
        try answers.print(a, "{?t} {s}\n", .{ r.err, harness.status(r.out) });
    }
    const text = try chat_fanout.fanoutText(a);
    const last = text[(std.mem.indexOf(u8, text, "; the last: ") orelse return error.TestUnexpectedResult) + "; the last: ".len ..];
    return .{ .answers = answers.items, .frames = try drained(a, &hub, &keys, &subs), .files = try tree(a, io, site.base), .counted = chat_fanout.fanout_failures - before, .last = last };
}

test "a member whose images.md will not take an entry: that surface fails for that member, counted and said in the old Zig's words, and their code, every other member's surfaces and the send are whole (metal-vmm QUEUE 172, 156(c)), the same both ways" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const roc = try feedFailRun(a, io);
    try freezeRun("feedFailRun", roc, "2f09f8284d0a7db3b5b52362faf823024a39d7a5f0af5895b9cd038c597b2bed");
    // It reached what it means to: both sends done, one failure each, the
    // last said in fanoutFailed's words; member 2's code and every other
    // member's images arrived, member 2's images never sent.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, roc.answers, "303 See Other"));
    try testing.expectEqual(@as(usize, 2), roc.counted);
    try testing.expectEqualStrings("images for member 2, IsDir, on ops/Standup", roc.last);
    for ([_][]const u8{ "== code:2\n", "== img:1\n", "== img:3\n", "== rec:2\n", "== ntf:2\n" }) |key| if (std.mem.indexOf(u8, roc.frames, key) == null) {
        std.debug.print("nothing published on {s}\n", .{key});
        return error.TestUnexpectedResult;
    };
    try testing.expect(std.mem.indexOf(u8, roc.frames, "== img:2\n") == null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, roc.files, "Sent by Steve at 2025-10-25T13:46:40Z, source MSG_Standup_2 in ops:\n```\ncode\n```"));
}

/// The most one request's memory held, served the old way or the Roc's: the
/// bytes its allocator was asked for at once (the response is written
/// elsewhere, as the kernel sends it).
fn requestPeak(a: Alloc, io: Io, raw: []const u8) !struct { peak: usize, answer: []const u8 } {
    // The bytes the request asks for, counted above an arena (below it,
    // the arena's slack would hide a copy that fits in a node it grew).
    var pages = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer pages.deinit();
    var request: @import("peak_alloc.zig").Peak = .{ .child = pages.allocator() };
    // As harness.serve, but what is written out is the connection's (the
    // kernel sends it as it goes), not the request heap's.
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = webbox.bus.Hub.init(io, a);
    var b = webbox.bus.Bus.of(&hub);
    _ = try @import("router.zig").route(&req, io, request.allocator(), &b);
    try out.writer.flush();
    return .{ .peak = request.most, .answer = out.written() };
}

test "a large topic's raw transcript costs one request what the old Zig's did, not a multiple of it (metal-vmm FEEDBACK 2026-10-26: 6x, and out of memory at 16 MB)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    // About 8 MB: two hundred messages of 40 KB.
    const msgs = try a.alloc([]const u8, 200);
    for (msgs, 0..) |*m, k| m.* = try std.fmt.allocPrint(a, "{d} {s}", .{ k, &@as([40_000]u8, @splat('x')) });
    try harness.writeTranscript(a, io, "1_2", "Big", msgs);
    @import("presence.zig").forgetForTest();
    const raw = try std.fmt.allocPrint(a, "GET /chat/c/1_2/Big/raw HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{steve});
    const roc = try requestPeak(a, io, raw);
    try testing.expect(roc.answer.len > 8_000_000);
    // Frozen (metal-vmm QUEUE 263d): the day the old Zig retired, it held
    // 12,023,880 bytes for this 8,014,703-byte transcript, the Roc 12,025,551:
    // one and a half times the answer. Its bound, and the Roc call's small
    // change beside it.
    try testing.expect(roc.peak <= roc.answer.len + roc.answer.len / 2 + 256 * 1024);
}

// ── a conversation's page and its sidebar, both ways ─────────────────────

/// When every page below is asked: the presence window's edges are this
/// time's.
const page_now: i64 = 1_761_400_000;

/// The pages, each as whom (0 Steve, 1 Debbie): a DM's, seen by each of
/// its two members, and a channel's.
const page_asks = [_]struct { cookie: usize, target: []const u8 }{
    .{ .cookie = 0, .target = "/chat/c/1_2/Plans" },
    .{ .cookie = 0, .target = "/chat/c/1_2/zeta" },
    .{ .cookie = 1, .target = "/chat/c/1_2/Other" },
    .{ .cookie = 0, .target = "/channel/ops/Standup" },
    .{ .cookie = 1, .target = "/channel/ops/Standup" },
};

/// The pages on a fresh site, served the old way or the Roc's: each
/// answer, and how many channels were counted malformed while they were.
fn pageRun(a: Alloc, io: Io) !struct { answers: [][]const u8, malformed: usize } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const presence = @import("presence.zig");
    // Names a page escapes: quotes, markup, an entity, a script's end.
    const cookies = [_][]const u8{
        try harness.memberSession(a, io, "1", "Steve"),
        try harness.memberSession(a, io, "2", "Deb \"the\" <b>&amp;</script>"),
    };
    for ([_][2][]const u8{ .{ "3", "Ann" }, .{ "4", "Bo" }, .{ "5", "Cy" }, .{ "6", "Di" }, .{ "10", "Ten" } }) |m| _ = try harness.memberSession(a, io, m[0], m[1]);
    // Topics in no order on disk, one with markup in its name (put there
    // by hand: the store names no file so, but a listing lists it).
    for ([_][]const u8{ "zeta", "Plans", "Other", "Alpha" }) |t| try harness.writeTranscript(a, io, "1_2", t, &.{"x"});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_2"), "sessions", "a<b.md" }), .data = "x" });
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"x"});
    try harness.writeTranscript(a, io, "channels/ops", "Later", &.{"x"});
    // Steve's channels (ops, Zed), one he is not in (aaa), and a malformed
    // one, skipped and counted by each listing.
    const root = store.chat_root;
    for ([_][2][]const u8{ .{ "ops", "1\n2\n" }, .{ "Zed", "1\n" }, .{ "aaa", "3\n" }, .{ "bad", "1\nnot a uid\n" } }) |c|
        try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ root, "channels", try std.fmt.allocPrint(a, "{s}.channel", .{c[0]}) }), c[1], .{});
    // Pins in no order, one stale (no longer a topic), a blank line.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ root, "users", "1", "pinned-sessions", "1_2" }), "Stale\nzeta\n\n Plans\r\n", .{});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ root, "users", "1", "pinned-sessions", "ops" }), "Gone\nLater\n", .{});
    // **THE WINDOW'S EDGES, SET BY THE SAME CALLS BOTH WAYS**: Debbie seen
    // 4:59 ago, Ann 5:00, Bo 5:01, Di a second ago; Cy and Ten never.
    presence.forgetForTest();
    const t = Now.at(page_now);
    for ([_]struct { []const u8, i64 }{ .{ "2", -299 }, .{ "3", -300 }, .{ "4", -301 }, .{ "6", -1 } }) |seen| _ = presence.markActive(seen[0], t.plus(seen[1]));

    chat_router.test_now = t;
    defer chat_router.test_now = null;
    const before = chat_paths.malformed_channels;
    const answers = try a.alloc([]const u8, page_asks.len);
    for (page_asks, answers) |p, *got| got.* = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ p.target, cookies[p.cookie] }));
    return .{ .answers = answers, .malformed = chat_paths.malformed_channels - before };
}

/// That `want` is in `page` after `from`; where it ends.
fn after(page: []const u8, from: usize, want: []const u8) !usize {
    const i = std.mem.indexOfPos(u8, page, from, want) orelse {
        std.debug.print("not after {d}: {s}\nin: {s}\n", .{ from, want, page });
        return error.TestUnexpectedResult;
    };
    return i + want.len;
}

test "a conversation's page (its viewer, sidebar and limits the Roc's, over list_accounts!, check_online!, the channels, the pins file, the topics and limits!) is the old Zig's, byte for byte, a DM's and a channel's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const roc = try pageRun(a, io);
    for (roc.answers) |r| try testing.expectEqualStrings("200 OK", harness.status(r));
    try freezeRun("pageRun", roc, "9bafdf5e742ce8c7b1520e82a46342721eff3053a7e45f089212ff417c052269");
    // Each listing met the malformed channel and counted it.
    try testing.expectEqual(page_asks.len, roc.malformed);

    // **WHAT THE PAGE SAYS, NOT ONLY THAT IT AGREES** (a change to the
    // shared Zig moves both ways at once). Steve's DM page: the others by
    // numeric id, never the viewer; online only within the window (4:59
    // and a second ago), never at 5:00, 5:01 or never seen.
    const page = roc.answers[0];
    var at = try after(page, 0, "{\"conversations\":[");
    // Every `<` of the page's JSON as `<` (html.scriptSafe, metal-vmm QUEUE 266).
    at = try after(page, at, "{\"id\":\"uid:2\",\"label\":\"Deb \\\"the\\\" \\u003cb>&amp;\\u003c/script>\",\"url\":\"/chat/c/1_2\",\"active\":true,\"online\":true},");
    at = try after(page, at, "{\"id\":\"uid:3\",\"label\":\"Ann\",\"url\":\"/chat/c/1_3\",\"active\":false},");
    at = try after(page, at, "{\"id\":\"uid:4\",\"label\":\"Bo\",\"url\":\"/chat/c/1_4\",\"active\":false},");
    at = try after(page, at, "{\"id\":\"uid:5\",\"label\":\"Cy\",\"url\":\"/chat/c/1_5\",\"active\":false},");
    at = try after(page, at, "{\"id\":\"uid:6\",\"label\":\"Di\",\"url\":\"/chat/c/1_6\",\"active\":false,\"online\":true},");
    at = try after(page, at, "{\"id\":\"uid:10\",\"label\":\"Ten\",\"url\":\"/chat/c/1_10\",\"active\":false},");
    // The member's channels by bytes (Zed before ops), never one they are
    // not in, never the malformed one.
    at = try after(page, at, "{\"id\":\"ch:Zed\",\"label\":\"# Zed\",\"url\":\"/channel/Zed\",\"active\":false},{\"id\":\"ch:ops\",\"label\":\"# ops\",\"url\":\"/channel/ops\",\"active\":false}],");
    // The pins that are topics, the stale one dropped; then the rest, by bytes.
    at = try after(page, at, "\"pinned_sessions\":[{\"id\":\"Plans\",\"label\":\"Plans\",\"url\":\"/chat/c/1_2/Plans\",\"active\":true},{\"id\":\"zeta\",");
    _ = try after(page, at, "\"topics\":[{\"id\":\"Alpha\",\"label\":\"Alpha\",\"url\":\"/chat/c/1_2/Alpha\",\"active\":false},{\"id\":\"Other\",\"label\":\"Other\",\"url\":\"/chat/c/1_2/Other\",\"active\":false},{\"id\":\"a\\u003cb\",");
    for (roc.answers) |r| try testing.expect(std.mem.indexOf(u8, r, "Stale") == null and std.mem.indexOf(u8, r, "ch:aaa") == null and std.mem.indexOf(u8, r, "ch:bad") == null and std.mem.indexOf(u8, r, "uid:1\",\"label\":\"Steve\",\"url\":\"/chat/c/1_1") == null);
    // **THE LIMITS ARE THE HOST'S CONSTANTS**, each in its own place.
    const chat_upload = @import("chat_upload.zig");
    _ = try after(page, 0, try std.fmt.allocPrint(a, "data-upload-image-max=\"{d}\" data-upload-video-max=\"{d}\" data-upload-accept=\"{s}\" data-search-min=\"{d}\"", .{ chat_upload.image_max, chat_upload.video_max, chat_upload.accept, @import("search_tokens.zig").min_len }));
    try testing.expect(chat_upload.image_max != chat_upload.video_max);
    // Debbie's view: Steve, seen as he asked his pages, online.
    _ = try after(roc.answers[2], 0, "{\"id\":\"uid:1\",\"label\":\"Steve\",\"url\":\"/chat/c/1_2\",\"active\":true,\"online\":true}");
    // The channel's page: its pin, the stale one dropped.
    _ = try after(roc.answers[3], 0, "\"pinned_sessions\":[{\"id\":\"Later\",\"label\":\"Later\",\"url\":\"/channel/ops/Later\",\"active\":false}],\"topics\":[{\"id\":\"Standup\"");
}

test "Host.check_online! is presence.isOnline at the request's time: generated last-seen times at the window's edge (online before 5:00, offline at and after it), and never seen offline" {
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const presence = @import("presence.zig");
    presence.forgetForTest();
    defer presence.forgetForTest();
    const t = Now.at(page_now);
    var rng = std.Random.DefaultPrng.init(0x0711e);
    const r = rng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ids: [60][]const u8 = undefined;
    var ago: [60]i64 = undefined;
    var edges: [3]usize = @splat(0);
    for (&ids, &ago, 0..) |*id, *s, k| {
        id.* = try std.fmt.allocPrint(arena.allocator(), "{d}", .{k + 100});
        // 4:59, 5:00 or 5:01 ago, give or take nothing: the edge itself.
        s.* = 299 + r.intRangeAtMost(i64, 0, 2);
        edges[@intCast(s.* - 299)] += 1;
        _ = presence.markActive(id.*, t.plus(-s.*));
    }
    try testing.expect(edges[0] > 0 and edges[1] > 0 and edges[2] > 0);
    var call: chat_router.Call = .{ .req = undefined, .io = undefined, .alloc = arena.allocator(), .bus = undefined, .now = t };
    const Presence = @import("roc_chat").Presence;
    for (ids, ago) |id, s| {
        const got = chat_router.Call.online(&call, id);
        try testing.expectEqual(if (s < 300) Presence.online else Presence.offline, got);
        try testing.expectEqual(presence.isOnline(id, t), got == .online);
    }
    try testing.expectEqual(Presence.offline, chat_router.Call.online(&call, "99"));
    // **AFTER A FAILURE THE HOST DOES NOTHING MORE**: offline, nothing read.
    call.failed = error.IsDir;
    try testing.expectEqual(Presence.offline, chat_router.Call.online(&call, ids[0]));
}
