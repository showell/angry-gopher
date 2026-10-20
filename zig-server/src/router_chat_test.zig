//! router.zig's tests: chat's routes.

const std = @import("std");
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
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // No markdown field at all; one that is only whitespace.
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "cid=x")));
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=+%0A+&cid=x")));
    // A message that began DROP_ON_FLOOR is a message.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=DROP_ON_FLOOR+is+a+phrase&cid=y")));
    // A code block's indentation stays.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=++++code%0A++++more&cid=z")));
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
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const page = try harness.postForm(a, io, "/login/full", "x=y", "name=Bob%3Cx%3E&password=pw&action=register");
    try testing.expect(std.mem.indexOf(u8, page, "set-cookie: __Host-gopher_auth=") == null);
    try testing.expect(std.mem.indexOf(u8, page, "Names can use only") != null);
    try testing.expectEqual(@as(?[]const u8, null), try users.findMemberByName(io, a, "Bobx"));
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
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    for ([_][]const u8{ "markdown=100%zz&cid=x", "markdown=a&markdown=b&cid=x", "markdown=50%&cid=x" }) |bad| {
        try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, bad)));
    }
    const raw = (try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Plans")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_store.decodeChatFile(a, raw)).len);
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
    try testing.expect((try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Nowhere")) == null);
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
    const raw = (try chat_store.rawSession(io, a, try chat_store.dmConvDir(a, "1_2"), "Fresh")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_store.decodeChatFile(a, raw)).len);
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
    const dir = try chat_store.dmConvDir(a, "1_2");
    const msgs = try chat_store.decodeChatFile(a, (try chat_store.rawSession(io, a, dir, "Plans")).?);
    try testing.expectEqualStrings("Steve", msgs[msgs.len - 1].from);
    try testing.expectEqualStrings("1", (try chat_count.lastMessage(io, a, dir, "Plans")).?.uid);
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
    const me = try harness.signedUid(a, try player.allocate(io, a, "Ada"));
    const ada = try users.allocateUser(io, a, "Ada");
    try users.setUserPassword(io, a, ada, "a password for Ada");
    const cookies = try std.fmt.allocPrint(a, "{s}; __Host-gopher_auth={s}", .{ me, (try users.signSessionNow(io, a, ada)).? });
    const got = try harness.postAs(a, io, "/chat/notifications", cookies, &@as([100]u8, @splat('x')));
    try testing.expectEqualStrings("405 Method Not Allowed", harness.status(got));
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
    const pinned = try chat_state.pinnedSessions(io, a, "1", "1_2");
    try testing.expectEqual(@as(usize, 1), pinned.len);
    try testing.expectEqualStrings("Plans", pinned[0]);
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/unpin", steve, "")));
    try testing.expectEqual(@as(usize, 0), (try chat_state.pinnedSessions(io, a, "1", "1_2")).len);
}
