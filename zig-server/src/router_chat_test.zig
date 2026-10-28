//! router.zig's tests: chat's routes.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_codec = @import("chat_codec.zig");
const player = @import("player.zig");
const users = @import("users.zig");
const mem_meter = @import("webbox").mem_meter;
const testing = std.testing;
const harness = @import("router_harness.zig");

// ── the normalization hunt's app findings (metal-vmm QUEUE 156) ──────────────

test "route: a new topic differing only in case from one there is refused, 409, where the store would merge them (156(a))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expectEqualStrings("409 Conflict", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=plans")));
    try testing.expectEqualStrings("409 Conflict", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=PLANS")));
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=New")));
}

test "route: a send that would store nothing is refused, 400, and a message is stored as sent (156(b))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // No markdown field at all; one that is only whitespace.
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "cid=x")));
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=+%0A+&cid=x")));
    // Bytes that are not UTF-8 (Latin-1's é): not text, so not stored.
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=caf%E9&cid=x")));
    // A message that began DROP_ON_FLOOR is a message.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=DROP_ON_FLOOR+is+a+phrase&cid=y")));
    // A code block's indentation stays.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=++++code%0A++++more&cid=z")));
    const raw = (try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Plans")).?;
    const msgs = try chat_codec.decodeChatFile(a, raw);
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
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const page = try harness.postForm(a, io, "/login/full", "x=y", "name=Bob%3Cx%3E&password=pw&action=register");
    try testing.expect(std.mem.indexOf(u8, page, "set-cookie: __Host-gopher_auth=") == null);
    try testing.expect(std.mem.indexOf(u8, page, "Names can use only") != null);
    try testing.expectEqual(@as(?[]const u8, null), try users.findMemberByName(io, a, "Bobx"));
    // A name whose bytes are not UTF-8 is refused, and makes no account.
    const latin1 = try harness.postForm(a, io, "/login/full", "x=y", "name=Jos%E9&password=pw&action=register");
    try testing.expect(std.mem.indexOf(u8, latin1, "set-cookie: __Host-gopher_auth=") == null);
    try testing.expect(std.mem.indexOf(u8, latin1, "not readable text") != null);
    try testing.expectEqual(@as(?[]const u8, null), try users.findMemberByName(io, a, "Jos\xe9"));
    // Nor logs in as the member the cleaned name would have been.
    _ = try harness.memberSession(a, io, "1", "Steve");
    const as_steve = try harness.postForm(a, io, "/login/full", "x=y", "name=Steve%3C&password=pw&action=login");
    try testing.expect(std.mem.indexOf(u8, as_steve, "set-cookie: __Host-gopher_auth=") == null);
}

test "route: one form decoder: a bad escape or a field sent twice is a 400 on every form, where chat took them and players refused them as a 500 (156(i))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    for ([_][]const u8{ "markdown=100%zz&cid=x", "markdown=a&markdown=b&cid=x", "markdown=50%&cid=x" }) |bad| {
        try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, bad)));
    }
    const raw = (try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Plans")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_codec.decodeChatFile(a, raw)).len);
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postForm(a, io, "/play", "x=y", "name=Ada%zz&next=%2Fgame")));
    // A well-formed escape still decodes.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=100%25&cid=y")));
}

test "route: a topic that is not there is a 404 that says so, on every tail but send, and never becomes where /chat/default resumes; a channel not the viewer's says why (156(j))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    const page = try harness.UidSite.ask(a, io, "/chat/c/1_2/Nowhere", steve);
    try testing.expectEqualStrings("404 Not Found", harness.status(page));
    try testing.expect(std.mem.indexOf(u8, page, "Nowhere") != null);
    for ([_][]const u8{ "/chat/c/1_2/Nowhere/raw", "/chat/c/1_2/Nowhere/stream", "/chat/c/1_2/Nowhere/reactions" }) |t|
        try testing.expectEqualStrings("404 Not Found", harness.status(try harness.UidSite.ask(a, io, t, steve)));
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Nowhere/react", steve, "msg=1&emoji=%F0%9F%91%8D")));
    try testing.expect((try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Nowhere")) == null);
    // Another case is the same topic (Steve, 2026-10-02).
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, "/chat/c/1_2/PLANS/raw", steve)));
    // The resume pointer still names Plans.
    const last = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions", "1_2" });
    try testing.expectEqualStrings("Plans\n", try harness.UidSite.disk.read(io, a, last, .limited(64)));
    // A channel the viewer is not in: a page that says why, worded as for one that is not there.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n", .{});
    const removed = try harness.UidSite.ask(a, io, "/channel/quiet", steve);
    const absent = try harness.UidSite.ask(a, io, "/channel/nothere", steve);
    try testing.expectEqualStrings("404 Not Found", harness.status(removed));
    try testing.expectEqualStrings("404 Not Found", harness.status(absent));
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
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const chat_state = @import("chat_state.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    // /chat, its bookmark on a conversation with no topic.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-conv" }), "1_2\n", .{});
    const landed = try harness.UidSite.ask(a, io, "/chat/default", steve);
    try testing.expectEqualStrings("303 See Other", harness.status(landed));
    try testing.expect(std.mem.indexOf(u8, landed, "location: /chat/c/1_2\r\n") != null);
    // A send to a topic not yet there makes it.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Fresh/send", steve, "markdown=first&cid=x")));
    const raw = (try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Fresh")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_codec.decodeChatFile(a, raw)).len);
    _ = chat_state;
}

test "route: a send and a reaction store their author's name and uid each where it goes, never the one for the other" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const chat_count = @import("chat_count.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=hello&cid=x")));
    const dir = try chat_paths.dmConvDir(a, "1_2");
    const msgs = try chat_codec.decodeChatFile(a, (try chat_paths.readTranscript(io, a, dir, "Plans")).?);
    try testing.expectEqualStrings("Steve", msgs[msgs.len - 1].from);
    try testing.expectEqualStrings("1", chat_count.readCount(io, a, dir, "Plans").?.last.?.uid);
    const n = try std.fmt.allocPrint(a, "msg={d}&emoji=%F0%9F%91%8D", .{msgs.len});
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/react", steve, n)));
    const line = try chat_store.readReactions(io, a, dir, "Plans");
    try testing.expect(std.mem.indexOf(u8, line, "\"uid\":\"1\",\"from\":\"Steve\"") != null);
}

test "route: a message saved to the reading list is found again at the place it was saved from" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const reading_list = @import("reading_list.zig");
    const docs_store = @import("docs_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const form = "conv=1_2&sid=Plans&id=Plans_3&from=Debbie&at=Jun+22&body=hello&note=later";
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/chat/docs/save_to_reading_list", steve, form)));
    const refs = try reading_list.parseRefs(a, try docs_store.readUserDoc(io, a, "1", reading_list.reading_list_slug));
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("1_2", refs[0].conv);
    try testing.expectEqualStrings("Plans", refs[0].sid);
    try testing.expectEqualStrings("Plans_3", refs[0].id);
}

test "route: a topic's saved ids are the reading list's refs to that topic, whatever else the list holds, and none when there is no list (metal-vmm QUEUE 273)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    const list = struct {
        fn write(al: std.mem.Allocator, i: std.Io, text: []const u8) !void {
            try harness.UidSite.disk.write(i, al, try @import("docs_store.zig").docPath(al, "1", "reading-list"), text, .{});
        }
    }.write;
    const body = struct {
        fn of(answer: []const u8) []const u8 {
            const at = std.mem.indexOf(u8, answer, "\r\n\r\n").?;
            return answer[at + 4 ..];
        }
    }.of;
    // No list: nothing saved.
    try testing.expectEqualStrings("[]", body(try harness.UidSite.ask(a, io, "/chat/c/1_2/Plans/saved", steve)));
    // An empty list: nothing saved.
    try list(a, io, "");
    try testing.expectEqualStrings("[]", body(try harness.UidSite.ask(a, io, "/chat/c/1_2/Plans/saved", steve)));
    // Refs to this topic, to another topic and another conversation, a
    // channel ref whose name is this DM's key (matched by the key's text,
    // after every DM ref), malformed ones (no anchor, a bad id, an empty
    // part, a cut-off end), and bytes that are not UTF-8.
    try list(a, io, "[open](/chat/c/1_2/Plans#msg-Plans_3) and /chat/c/1_2/Other#msg-Other_1\n" ++
        "/channel/1_2/Plans#msg-Plans_9 /chat/c/1_3/Plans#msg-Plans_2\n" ++
        "/chat/c/1_2/Plans#msg-bad /chat/c/1_2/Plans /chat/c//Plans#msg-Plans_5 /chat/c/1_2/#msg-Plans_6\n" ++
        "/chat/c/1_2/Plans#msg-Plans_4) and again /chat/c/1_2/Plans#msg-Plans_3 \xff\n" ++
        "/chat/c/1_2/Plans#msg-Plans_7");
    try testing.expectEqualStrings("[\"Plans_3\",\"Plans_4\",\"Plans_3\",\"Plans_7\",\"Plans_9\"]", body(try harness.UidSite.ask(a, io, "/chat/c/1_2/Plans/saved", steve)));
    // Saved in another topic only: nothing here.
    try list(a, io, "/chat/c/1_2/Other#msg-Other_1\n");
    try testing.expectEqualStrings("[]", body(try harness.UidSite.ask(a, io, "/chat/c/1_2/Plans/saved", steve)));
}

test "route: the conversation page hands the client the upload caps and the accepted types, the server's own, where chat_compose.js kept copies (metal-vmm QUEUE 157(d))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_upload = @import("chat_upload.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    const page = try harness.UidSite.ask(a, io, "/chat/c/1_2/Plans", steve);
    try testing.expect(std.mem.indexOf(u8, page, try std.fmt.allocPrint(a, "data-upload-image-max=\"{d}\"", .{@import("limits.zig").body.upload_image})) != null);
    try testing.expect(std.mem.indexOf(u8, page, try std.fmt.allocPrint(a, "data-upload-video-max=\"{d}\"", .{@import("limits.zig").body.upload_video})) != null);
    try testing.expect(std.mem.indexOf(u8, page, "data-upload-accept=\"" ++ chat_upload.accept ++ "\"") != null);
    // Every type the server takes is in the list, and nothing else.
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, chat_upload.accept, ',');
    while (it.next()) |mime| : (n += 1) try testing.expect(chat_upload.extOf(mime) != null);
    try testing.expectEqual(chat_upload.accepted.len, n);
}

test "a stream is a GET's: a POST to one is 405, its body never read nor held (metal-vmm QUEUE 176.3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const me = try harness.signedUid(a, try player.allocate(io, a, .literal("Ada")));
    const ada = try users.allocateUser(io, a, .literal("Ada"));
    try users.setUserPassword(io, a, ada, "a password for Ada");
    const cookies = try std.fmt.allocPrint(a, "{s}; __Host-gopher_auth={s}", .{ me, (try users.signSessionNow(io, a, ada)).? });
    const got = try harness.postAs(a, io, "/chat/notifications", cookies, &@as([100]u8, @splat('x')));
    try testing.expectEqualStrings("405 Method Not Allowed", harness.status(got));
}

test "route: the page and what a topic serves only answer a read: a POST there is 405, a GET is served" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{"hello"});
    const chat_store = @import("chat_store.zig");
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "Plans.uploads", "0123456789abcdef0123456789abcdef.png" }), "\x89PNG\r\n\x1a\n", .{});
    for ([_][]const u8{ "", "/raw", "/download", "/saved", "/uploads/0123456789abcdef0123456789abcdef.png" }) |tail| {
        const path = try std.fmt.allocPrint(a, "/chat/c/1_2/Plans{s}", .{tail});
        errdefer std.debug.print("{s}\n", .{path});
        try testing.expectEqualStrings("405 Method Not Allowed", harness.status(try harness.postAs(a, io, path, steve, "x=y")));
        try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, path, steve)));
    }
}

test "route: pin puts a topic in the viewer's Pinned group and unpin takes it out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_state = @import("chat_state.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/pin", steve, "")));
    const pinned = try chat_state.pinnedTopics(io, a, "1", "1_2");
    try testing.expectEqual(@as(usize, 1), pinned.len);
    try testing.expectEqualStrings("Plans", pinned[0]);
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/unpin", steve, "")));
    try testing.expectEqual(@as(usize, 0), (try chat_state.pinnedTopics(io, a, "1", "1_2")).len);
}

test "route: the chat's gate sends an outsider to sign in and back to the request's own path, and a path that is none on this site is a 400, never a redirect (metal-vmm QUEUE 250)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    for ([_][2][]const u8{ .{ "/chat/c/1_2/general", "/login/full?next=/chat/c/1_2/general" }, .{ "/channel/ops", "/login/full?next=/channel/ops" } }) |c| {
        const away = try harness.get(a, io, c[0]);
        try testing.expectEqualStrings("303 See Other", harness.status(away));
        try testing.expectEqualStrings(c[1], harness.responseHeader(away, "location").?);
    }
    // A backslash: a browser reads it as a slash, so the target is no path
    // on this site.
    for ([_][]const u8{ "/chat/c/1_2/a\\b", "/channel/ops\\x" }) |bad| {
        const refused = try harness.get(a, io, bad);
        try testing.expectEqualStrings("400 Bad Request", harness.status(refused));
        try testing.expect(harness.responseHeader(refused, "location") == null);
    }
}

test "route: a chat path that is not UTF-8 is the site's 400, before the gate, never a panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    for ([_][]const u8{ "/chat/\xff", "/channel/ops/\xc3" }) |bad| {
        const refused = try harness.get(a, io, bad);
        try testing.expectEqualStrings("400 Bad Request", harness.status(refused));
    }
}

test "route: the welcome DM is seeded on a member's /chat, once, from the host; a member already there gets it on their next visit; with no host, none; one that will not store is never a failed /chat, and is tried again (metal-vmm QUEUE 279)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_count = @import("chat_count.zig");
    // No host yet: Eve's /chat seeds nothing.
    const eve = try harness.memberSession(a, io, "5", "Eve");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, "/chat", eve)));
    try testing.expect(!try harness.UidSite.disk.has(io, a, try chat_paths.dmConvDir(a, "1_5")));
    // The host arrives: Eve's next /chat seeds the welcome and lands on it;
    // the one after leaves it at one message.
    _ = try harness.memberSession(a, io, "1", "Steve");
    const dir = try chat_paths.dmConvDir(a, "1_5");
    for (0..2) |_| {
        const got = try harness.UidSite.ask(a, io, "/chat", eve);
        try testing.expect(std.mem.indexOf(u8, got, "location: /chat/c/1_5/general\r\n") != null);
        try testing.expectEqual(@as(usize, 1), try chat_count.messageCount(io, a, dir, "general"));
    }
    const transcript = (try chat_paths.readTranscript(io, a, dir, "general")).?;
    try testing.expect(std.mem.indexOf(u8, transcript, "from: Steve\n") != null and std.mem.indexOf(u8, transcript, "uid: 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, transcript, "Hi, this is an automated message from Steve. Please say hello and Steve will get back to you soon.") != null);
    // A DM whose topics will not list (a file where its folder goes): no
    // welcome, and /chat is served all the same.
    const ann = try harness.memberSession(a, io, "3", "Ann");
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_3"), "sessions" }), "", .{});
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, "/chat", ann)));
    // Mended, the next visit welcomes.
    try harness.UidSite.disk.remove(io, a, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_3"), "sessions" }));
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat", ann), "location: /chat/c/1_3/general\r\n") != null);
}
