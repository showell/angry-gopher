//! router.zig's tests: search.

const std = @import("std");
const users = @import("users.zig");
const streams = @import("webbox").bus;
const Bus = streams.Bus;
const Hub = streams.Hub;
const mem_meter = @import("webbox").mem_meter;
const search_index = @import("search_index.zig");
const testing = std.testing;
const harness = @import("router_harness.zig");

// ── search (metal-vmm QUEUE 155) ─────────────────────────────────────────────

test "route: /admin/search finds a key in every conversation the admin can see, DMs and channels, ASCII case folded, and nowhere else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const me = try harness.adminSession(a, io);
    const chat_store = @import("chat_store.zig");
    const disk = @import("webbox").store;
    // Two more members; the admin is in channel "general", not in "quiet".
    for ([_][2][]const u8{ .{ "2", "Debbie" }, .{ "3", "Apoorva" } }) |m| {
        try users.setUserName(io, a, m[0], m[1]);
        try users.setUserPassword(io, a, m[0], "pw");
    }
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n3\n", .{});
    const transcripts = [_]struct { dir: []const u8, sid: []const u8, body: []const u8 }{
        .{ .dir = "1_2", .sid = "ChitChat", .body = "MSG_ChitChat_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nthe page LAYOUT is off" ++ chat_store.sep ++ "MSG_ChitChat_2\nfrom: Claude\ndate: 2026-10-10T00:01:00Z\n\nnothing to see" },
        .{ .dir = "channels/general", .sid = "Trips", .body = "MSG_Trips_1\nfrom: Debbie\ndate: 2026-10-10T00:02:00Z\n\na long layover in Denver" ++ chat_store.sep ++ "MSG_Trips_2\nfrom: Debbie\ndate: 2026-10-10T00:02:30Z\n\n<script>alert(1)</script> lay" },
        .{ .dir = "2_3", .sid = "Cards", .body = "MSG_Cards_1\nfrom: Apoorva\ndate: 2026-10-10T00:03:00Z\n\ndeal the seven" },
        // Not the admin's: a DM between two others, and a channel the admin is not in.
        .{ .dir = "2_3", .sid = "Private", .body = "MSG_Private_1\nfrom: Debbie\ndate: 2026-10-10T00:04:00Z\n\nthe layaway plan" },
        .{ .dir = "channels/quiet", .sid = "Hush", .body = "MSG_Hush_1\nfrom: Apoorva\ndate: 2026-10-10T00:05:00Z\n\na layer cake" },
    };
    for (transcripts) |t| {
        const path = try std.fs.path.join(a, &.{ chat_store.chat_root, t.dir, "sessions", try std.fmt.allocPrint(a, "{s}.md", .{t.sid}) });
        try disk.write(io, a, path, t.body, .{});
    }
    const got = try harness.UidSite.ask(a, io, "/admin/search?key=lay", me);
    try testing.expectEqualStrings("200 OK", harness.status(got));
    try testing.expect(std.mem.indexOf(u8, got, "/chat/c/1_2/ChitChat#msg-ChitChat_1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "/channel/general/Trips#msg-Trips_1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "ChitChat_2") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Private_1") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Hush_1") == null);
    try testing.expect(std.mem.indexOf(u8, got, "3 messages match, of 4 in 2 transcripts") != null);
    // A message's text is escaped on the page.
    try testing.expect(std.mem.indexOf(u8, got, "&lt;script&gt;alert(1)&lt;/script&gt; lay") != null);
    try testing.expect(std.mem.indexOf(u8, got, "<script>alert") == null);
    // **ONLY A GET FROM THIS SITE SEARCHES**: a HEAD, and a link from another
    // site that the admin's cookie follows, get the form and read nothing.
    const admin_search = @import("admin_search.zig");
    const read_before = admin_search.transcripts_read;
    const head = try harness.serve(a, io, try std.fmt.allocPrint(a, "HEAD /admin/search?key=lay HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expectEqualStrings("200 OK", harness.status(head));
    try testing.expectEqual(read_before, admin_search.transcripts_read);
    const cross = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET /admin/search?key=lay HTTP/1.1\r\nHost: x\r\nSec-Fetch-Site: cross-site\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expect(std.mem.indexOf(u8, cross, "messages match") == null);
    try testing.expect(std.mem.indexOf(u8, cross, "does not run; press Search") != null);
    const typed = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET /admin/search?key=lay HTTP/1.1\r\nHost: x\r\nSec-Fetch-Site: none\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expect(std.mem.indexOf(u8, typed, "3 messages match") != null);
}

test "route: Recent's Who cell names the last author where the .count is behind its transcript, \"You\" for the viewer (the box's must-fix)" {
    // A sidecar write that failed leaves the .count one message behind. With
    // .lastauthor gone (153(1)) the cell showed nobody; the author is found
    // by the last message's name, as login finds members.
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
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    const first = "MSG_ChitChat_1\nfrom: Debbie\ndate: 2026-10-10T00:00:00Z\n\nhello";
    try harness.writeTranscript(a, io, "1_2", "ChitChat", &.{}); // the folder
    const md = try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.md" });
    try harness.UidSite.disk.write(io, a, md, first ++ chat_store.sep ++ "MSG_ChitChat_2\nfrom: Steve\ndate: 2026-10-10T00:01:00Z\n\nhi back", .{});
    // The .count as it stood after the first message: one behind.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.count" }), try std.fmt.allocPrint(a, "1 {d}\n0 2\n", .{first.len}), .{});

    const mine = try harness.UidSite.ask(a, io, "/chat/recent", steve);
    try testing.expect(std.mem.indexOf(u8, mine, "\"who\":\"You\"") != null);
    const theirs = try harness.UidSite.ask(a, io, "/chat/recent", debbie);
    try testing.expect(std.mem.indexOf(u8, theirs, "\"who\":\"Steve\"") != null);
}

test "route: search suggests and finds only in what the viewer can see; a word only in another pair's DM is neither (metal-vmm 155(d))" {
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
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const chat_store = @import("chat_store.zig");

    const me = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Apoorva");
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n3\n", .{});
    try harness.writeTranscript(a, io, "1_2", "ChitChat", &.{ "the page LAYOUT is off", "\u{201C}Layover\u{201D} in Denver?" });
    try harness.writeTranscript(a, io, "channels/general", "Trips", &.{"a layout, again"});
    // Not mine: another pair's DM, and a channel I am not in.
    try harness.writeTranscript(a, io, "2_3", "Private", &.{"the layaway plan, secretly"});
    try harness.writeTranscript(a, io, "channels/quiet", "Hush", &.{"a layer cake, secretly"});

    const words = try harness.UidSite.ask(a, io, "/chat/search/words?prefix=LAY", me);
    try testing.expectEqualStrings("200 OK", harness.status(words));
    try testing.expect(std.mem.indexOf(u8, words, "{\"word\":\"layout\",\"count\":2}") != null);
    try testing.expect(std.mem.indexOf(u8, words, "{\"word\":\"layover\",\"count\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, words, "layaway") == null);
    try testing.expect(std.mem.indexOf(u8, words, "layer") == null);
    // A word in what I can see and in what I cannot: counted in mine only
    // ("the" is in 1_2 once, and in 2_3).
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/words?prefix=the", me), "{\"word\":\"the\",\"count\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/messages?word=the", me), "\"matched\":1,") != null);

    const found = try harness.UidSite.ask(a, io, "/chat/search/messages?word=layout", me);
    try testing.expect(std.mem.indexOf(u8, found, "\"matched\":2") != null);
    try testing.expect(std.mem.indexOf(u8, found, "\"conv\":\"/chat/c/1_2\",\"kind\":\"dm\",\"sid\":\"ChitChat\",\"id\":\"ChitChat_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, found, "\"conv\":\"/channel/general\",\"kind\":\"channel\",\"sid\":\"Trips\",\"id\":\"Trips_1\"") != null);
    // **THE LEAK**: words only in what others can see.
    chat_search.forgetAll();
    for ([_][]const u8{ "/chat/search/messages?word=secretly", "/chat/search/messages?word=layaway", "/chat/search/words?prefix=secr" }) |target| {
        const got = try harness.UidSite.ask(a, io, target, me);
        try testing.expectEqualStrings("200 OK", harness.status(got));
        try testing.expect(std.mem.indexOf(u8, got, "secretly") == null or std.mem.indexOf(u8, got, "\"word\":\"secretly\",\"matched\":0,\"unreadable\":0,\"messages\":[]") != null);
        try testing.expect(std.mem.indexOf(u8, got, "layaway plan") == null);
        try testing.expect(std.mem.indexOf(u8, got, "\"count\"") == null);
    }
    // And one who can see them finds them.
    const deb = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/messages?word=secretly", deb), "\"matched\":2") != null);

    // **A MESSAGE THAT LANDS IS FOUND**, without a build from the disk.
    var hub = Hub.init(io, a);
    var bus = Bus.of(&hub);
    const meta = chat_store.ConvMeta{ .kind = .dm, .members = &[_][]const u8{ "1", "2" } };
    _ = try chat_store.appendMessage(io, a, &bus, meta, try chat_store.dmConvDir(a, "1_2"), "1_2", "ChitChat", "Steve", "1", "zeppelins, tonight", "");
    chat_search.forgetAll();
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/messages?word=zeppelins", me), "\"matched\":1") != null);

    // **A FEW SEARCHES A SECOND**, then 429.
    chat_search.forgetAll();
    var refused = false;
    for (0..chat_search.per_second + 1) |_| {
        if (std.mem.eql(u8, harness.status(try harness.UidSite.ask(a, io, "/chat/search/words?prefix=la", me)), "429 Too Many Requests")) refused = true;
    }
    try testing.expect(refused);
}

test "search agrees with /admin/search: for every word, the baseline's messages that hold it (metal-vmm 155(c))" {
    // /admin/search matches a key as a substring ("lay" finds "player"); the
    // index, whole words. So for every key that is a word of the corpus, and
    // every viewer: the index's messages are exactly the baseline's whose
    // words include the key. The corpus stays under the baseline's 500
    // listed, and no transcript is too large for it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const tokens = @import("search_tokens.zig");
    const admin_search = @import("admin_search.zig");
    const chat_store = @import("chat_store.zig");
    const meter = mem_meter.useForTest(testing.allocator);
    defer meter.restore();
    const emptied = search_index.emptyForTest();
    defer emptied.end();

    for ([_][2][]const u8{ .{ "1", "Steve" }, .{ "2", "Debbie" }, .{ "3", "Apoorva" } }) |m| {
        try users.setUserName(io, a, m[0], m[1]);
        try users.setUserPassword(io, a, m[0], "pw");
    }
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "quiet.channel" }), "2\n3\n", .{});
    const vocabulary = [_][]const u8{
        "Layout",      "layout,",     "\u{201C}layout\u{201D}", "lay", "player", "LAY!", "(lay)", "layer",    "don't",                "don\u{2019}t",
        "caf\u{00E9}", "CAF\u{00C9}", "\u{65E5}\u{672C}",       "a",   "x1",     "e.g.", "3.14",  "**bold**", "\u{2014}dash\u{2014}", "plan",
    };
    const places = [_][2][]const u8{ .{ "1_2", "Alpha" }, .{ "1_2", "Beta" }, .{ "1_3", "Gamma" }, .{ "2_3", "Delta" }, .{ "channels/general", "Trips" }, .{ "channels/quiet", "Hush" } };
    // The words of each message by where it is: "<base> <sid> <id>".
    var holds: std.StringHashMapUnmanaged([]const u8) = .empty;
    var prng = std.Random.DefaultPrng.init(155);
    const rand = prng.random();
    for (places) |pl| {
        var bodies: std.ArrayList([]const u8) = .empty;
        for (0..rand.intRangeAtMost(usize, 1, 12)) |_| {
            var body: std.ArrayList(u8) = .empty;
            for (0..rand.intRangeAtMost(usize, 1, 8)) |w| {
                if (w > 0) try body.append(a, if (rand.boolean()) ' ' else '\n');
                try body.appendSlice(a, vocabulary[rand.uintLessThan(usize, vocabulary.len)]);
            }
            try bodies.append(a, body.items);
        }
        try harness.writeTranscript(a, io, pl[0], pl[1], bodies.items);
        const base = if (std.mem.startsWith(u8, pl[0], "channels/")) try std.fmt.allocPrint(a, "/channel/{s}", .{pl[0]["channels/".len..]}) else try std.fmt.allocPrint(a, "/chat/c/{s}", .{pl[0]});
        for (bodies.items, 1..) |body, n| try holds.put(a, try std.fmt.allocPrint(a, "{s} {s} {s}_{d}", .{ base, pl[1], pl[1], n }), body);
    }
    // Every key: every word of the corpus, folded.
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    var hit_it = holds.valueIterator();
    while (hit_it.next()) |body| {
        var it = tokens.words(body.*);
        while (it.next()) |w| try keys.put(a, try std.ascii.allocLowerString(a, w), {});
    }
    try testing.expect(keys.count() > 10);
    // Built; then messages that land after it, through appendMessage, as
    // the index takes them (and the disk, which the baseline reads).
    _ = search_index.ready(io, a).?;
    var hub = Hub.init(io, a);
    var bus = Bus.of(&hub);
    for (0..12) |n| {
        const pl = places[rand.uintLessThan(usize, places.len)];
        const channel = std.mem.startsWith(u8, pl[0], "channels/");
        const meta = chat_store.ConvMeta{ .kind = if (channel) .channel else .dm, .members = &[_][]const u8{} };
        var body: std.ArrayList(u8) = .empty;
        for (0..rand.intRangeAtMost(usize, 1, 6)) |w| {
            if (w > 0) try body.append(a, ' ');
            try body.appendSlice(a, vocabulary[rand.uintLessThan(usize, vocabulary.len)]);
        }
        const dir = try std.fs.path.join(a, &.{ chat_store.chat_root, pl[0] });
        const m = try chat_store.appendMessage(io, a, &bus, meta, dir, pl[0], pl[1], "Someone", "1", body.items, "");
        const base = if (channel) try std.fmt.allocPrint(a, "/channel/{s}", .{pl[0]["channels/".len..]}) else try std.fmt.allocPrint(a, "/chat/c/{s}", .{pl[0]});
        try holds.put(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ base, pl[1], m.id }), body.items);
        _ = n;
    }
    hit_it = holds.valueIterator();
    while (hit_it.next()) |body| {
        var it = tokens.words(body.*);
        while (it.next()) |w| try keys.put(a, try std.ascii.allocLowerString(a, w), {});
    }
    const idx = search_index.ready(io, a).?;
    var compared: usize = 0;
    for ([_][]const u8{ "1", "2", "3" }) |who| {
        const reach = try chat_store.visibleConvs(io, a, who);
        var key_it = keys.keyIterator();
        while (key_it.next()) |k| {
            const base_r = try admin_search.search(io, a, who, k.*);
            try testing.expect(base_r.matched == base_r.hits.len); // under its cap
            try testing.expectEqual(@as(usize, 0), base_r.unreadable + base_r.too_big);
            var want: std.StringHashMapUnmanaged(void) = .empty;
            for (base_r.hits) |h| {
                const where = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ h.base, h.sid, h.id });
                var it = tokens.words(holds.get(where).?);
                var has = false;
                while (it.next()) |w| {
                    if (std.ascii.eqlIgnoreCase(w, k.*) and w.len == k.len) has = true;
                }
                if (has) try want.put(a, where, {});
            }
            const got = try idx.messagesFor(a, reach, k.*, 10_000, .{});
            try testing.expectEqual(got.matched, got.hits.len);
            var got_set: std.StringHashMapUnmanaged(void) = .empty;
            for (got.hits) |h| try got_set.put(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ h.conv.base, h.msg.sid, h.msg.id }), {});
            if (want.count() != got_set.count()) {
                std.debug.print("viewer {s}, key \"{s}\": the baseline's messages holding it {d}, the index's {d}\n", .{ who, k.*, want.count(), got_set.count() });
                return error.Disagree;
            }
            var want_it = want.keyIterator();
            while (want_it.next()) |w| try testing.expect(got_set.contains(w.*));
            // And the words route counts it so (the box's review of 155).
            var counted: usize = 0;
            for (try idx.wordsFor(a, reach, k.*, 100_000)) |wc| {
                if (std.mem.eql(u8, wc.word, k.*)) counted = wc.count;
            }
            try testing.expectEqual(want.count(), counted);
            compared += 1;
        }
    }
    try testing.expect(compared > 30);
}

test "route: search answers each message's excerpt cut, the word marked as the index reads it, and says its own cap; the client copies neither (metal-vmm QUEUE 157(d))" {
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
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const me = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    // The word inside curly quotes and a comma, after a word that holds it
    // ("layouts"): the mark is the word the tokenizer reads, which the
    // client's regex once had to guess.
    const long = "x" ** 200;
    try harness.writeTranscript(a, io, "1_2", "ChitChat", &.{"see layouts, then \u{201C}LAYOUT\u{201D}, here " ++ long});
    const found = try harness.UidSite.ask(a, io, "/chat/search/messages?word=layout", me);
    try testing.expect(std.mem.indexOf(u8, found, "\"before\":\"see layouts, then \u{201C}\",\"mark\":\"LAYOUT\",\"after\":\"\u{201D}, here ") != null);
    try testing.expect(std.mem.indexOf(u8, found, "x\u{2026}\"") != null); // cut, and says so
    try testing.expect(std.mem.indexOf(u8, found, "\"markdown\":") == null); // the excerpt, not the message
    const words = try harness.UidSite.ask(a, io, "/chat/search/words?prefix=lay", me);
    try testing.expect(std.mem.indexOf(u8, words, try std.fmt.allocPrint(a, "\"most\":{d}", .{chat_search.most_words})) != null);
    // And the page carries the shortest word a search takes.
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", me, "topic=Plans")));
    const page = try harness.UidSite.ask(a, io, "/chat/c/1_2/Plans", me);
    try testing.expect(std.mem.indexOf(u8, page, try std.fmt.allocPrint(a, "data-search-min=\"{d}\"", .{@import("search_tokens.zig").min_len})) != null);
}

test "route: search's budget charges the excerpts it sends, not the whole messages, so big messages do not cut the list short (the review of 157)" {
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
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const me = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    // Thirty messages of 100 KB, each holding the word: 3 MB whole, past the
    // 2 MiB budget; their excerpts are a few KB.
    const big = "zeppelin " ++ "x" ** (100 << 10);
    var bodies: [30][]const u8 = undefined;
    for (&bodies) |*b| b.* = big;
    try harness.writeTranscript(a, io, "1_2", "Docs", &bodies);
    const found = try harness.UidSite.ask(a, io, "/chat/search/messages?word=zeppelin", me);
    try testing.expect(std.mem.indexOf(u8, found, "\"matched\":30") != null);
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, found, "\"mark\":\"zeppelin\""));
    try testing.expect(found.len < 64 << 10);
}
