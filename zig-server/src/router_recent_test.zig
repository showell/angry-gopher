//! /chat/recent's rows, held to what recent.zig `gatherRows` and
//! chat_count.zig `lastMessage` answered (metal-vmm QUEUE 277): the JSON the
//! page boots with over one tree that has every kind of row, pinned the day
//! the Roc took the gathering over, when this test passed against the Zig.

const std = @import("std");
const Io = @import("host_io").Io;
const harness = @import("router_harness.zig");
const chat_paths = @import("chat_paths.zig");
const chat_codec = @import("chat_codec.zig");
const chat_store = @import("chat_store.zig");
const users = @import("users.zig");

const testing = std.testing;
const disk = harness.UidSite.disk;

/// One stored block: `uid` empty for one written before blocks named their
/// author.
const Block = struct { from: []const u8, uid: []const u8 = "", at: []const u8 = "2026-10-10T00:00:00Z", body: []const u8 };

/// `blocks` as `sid`'s transcript in `dir`, numbered from 1; the offset each
/// block begins at, for a sidecar's second line.
fn transcript(a: std.mem.Allocator, io: Io, dir: []const u8, sid: []const u8, blocks: []const Block) ![]u64 {
    var t: std.ArrayList(u8) = .empty;
    const offsets = try a.alloc(u64, blocks.len);
    for (blocks, 0..) |b, i| {
        const msg: chat_store.ChatMessage = .{ .id = try std.fmt.allocPrint(a, "{s}_{d}", .{ sid, i + 1 }), .from = b.from, .at = b.at, .uid = b.uid, .markdown = b.body };
        const stored = try chat_codec.chatStoredForm(a, i, msg);
        offsets[i] = t.items.len + (if (i == 0) 0 else chat_store.sep.len);
        try t.appendSlice(a, stored);
    }
    try disk.write(io, a, try chat_paths.transcriptPath(a, dir, sid), t.items, .{});
    return offsets;
}

/// `sid`'s `.count` sidecar, `{size}` the transcript's size.
fn sidecar(a: std.mem.Allocator, io: Io, dir: []const u8, sid: []const u8, raw: []const u8) !void {
    const st = try disk.stat(io, a, try chat_paths.transcriptPath(a, dir, sid));
    const text = try std.mem.replaceOwned(u8, a, raw, "{size}", try std.fmt.allocPrint(a, "{d}", .{st.size}));
    const path = try std.fs.path.join(a, &.{ dir, "sessions", try std.fmt.allocPrint(a, "{s}.count", .{sid}) });
    try disk.write(io, a, path, text, .{});
}

/// `path`'s modification time, `secs` and half a second.
fn touch(io: Io, path: []const u8, secs: i96) !void {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = secs * std.time.ns_per_s + 500_000_000 } } });
}

test "route: /chat/recent's rows as gatherRows and lastMessage made them: DMs, a channel, an empty topic, a bad date, docs, and every sidecar a last message is read through, and one whose read fails a miss (metal-vmm QUEUE 276, 277, 284)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = @import("webbox").mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    // Two members who share a name (108's sign-up race), and one Steve has
    // no DM topics with.
    _ = try harness.memberSession(a, io, "4", "Twin");
    _ = try harness.memberSession(a, io, "5", "Twin");
    _ = try harness.memberSession(a, io, "6", "Quiet");

    const dm = try chat_paths.dmConvDir(a, "1_2");
    const big = try a.alloc(u8, chat_store.tail_window + 100);
    for (big, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));

    // A current record: its author stands, though the block names nobody.
    const cur = try transcript(a, io, dm, "Current", &.{ .{ .from = "Steve", .uid = "1", .body = "one" }, .{ .from = "Nobody", .at = "2026-10-10T01:00:00Z", .body = "the record says Debbie" } });
    try sidecar(a, io, dm, "Current", try std.fmt.allocPrint(a, "2 {{size}}\n{d} 2\n", .{cur[1]}));
    // A record one behind: the newer message's own uid, never the record's.
    _ = try transcript(a, io, dm, "Behind", &.{ .{ .from = "Debbie", .uid = "2", .body = "older" }, .{ .from = "Steve", .uid = "1", .at = "2026-10-10T02:00:00Z", .body = "newer, mine" } });
    try sidecar(a, io, dm, "Behind", "1 8\n0 2\n");
    // A last message too long for the window: read whole, and the record,
    // which speaks for exactly this transcript, names its author.
    const full = try transcript(a, io, dm, "Full", &.{ .{ .from = "Steve", .uid = "1", .body = "small" }, .{ .from = "Steve", .at = "2026-10-10T03:00:00Z", .body = big } });
    try sidecar(a, io, dm, "Full", try std.fmt.allocPrint(a, "2 {{size}}\n{d} 2\n", .{full[1]}));
    // A current record of one message, its block the file's first; and one
    // whose last body holds a line like the separator, escaped and back.
    _ = try transcript(a, io, dm, "Alone", &.{.{ .from = "Steve", .uid = "1", .at = "2026-10-10T11:00:00Z", .body = "alone" }});
    try sidecar(a, io, dm, "Alone", "1 {size}\n0 1\n");
    const nasty = try transcript(a, io, dm, "Nasty", &.{ .{ .from = "Steve", .uid = "1", .body = "innocent" }, .{ .from = "Debbie", .uid = "2", .at = "2026-10-10T12:00:00Z", .body = "before\n-------------\nafter" } });
    try sidecar(a, io, dm, "Nasty", try std.fmt.allocPrint(a, "2 {{size}}\n{d} 2\n", .{nasty[1]}));
    // A record that claims a message the topic does not have, and one whose
    // size is far past the file (never what a read is sized by).
    _ = try transcript(a, io, dm, "Ahead", &.{ .{ .from = "Debbie", .uid = "2", .body = "a" }, .{ .from = "Debbie", .uid = "2", .at = "2026-10-10T13:00:00Z", .body = "the real last" } });
    try sidecar(a, io, dm, "Ahead", "9 {size}\n0 1\n");
    _ = try transcript(a, io, dm, "FarSize", &.{.{ .from = "Debbie", .uid = "2", .at = "2026-10-10T14:00:00Z", .body = "modest" }});
    try sidecar(a, io, dm, "FarSize", "1 999999999999\n0 2\n");
    // A current record that says nobody is believed, though the block's
    // name is a member's now (a name reused after its member left).
    _ = try transcript(a, io, dm, "Reused", &.{.{ .from = "Debbie", .at = "2026-10-10T15:00:00Z", .body = "from someone since gone" }});
    try sidecar(a, io, dm, "Reused", "1 {size}\n0 -\n");
    // A record pointing at the wrong place: not believed, the whole read.
    _ = try transcript(a, io, dm, "Wrong", &.{ .{ .from = "Debbie", .uid = "2", .body = "a" }, .{ .from = "Debbie", .uid = "2", .at = "2026-10-10T04:00:00Z", .body = "b" } });
    try sidecar(a, io, dm, "Wrong", "2 {size}\n5 1\n");
    // No sidecar: the whole read, and a block from before `uid:` credited
    // to the one member it names.
    _ = try transcript(a, io, dm, "Fallback", &.{.{ .from = "Debbie", .at = "2026-10-10T05:00:00Z", .body = "by name" }});
    // Nobody: a name nobody has, a name two members share. A block with
    // no name at all is no message: the topic is dated by its file.
    _ = try transcript(a, io, dm, "Nameless", &.{.{ .from = "", .at = "2026-10-10T06:00:00Z", .body = "no name" }});
    try touch(io, try chat_paths.transcriptPath(a, dm, "Nameless"), 1790000009);
    _ = try transcript(a, io, dm, "Stranger", &.{.{ .from = "Gone", .at = "2026-10-10T07:00:00Z", .body = "left" }});
    _ = try transcript(a, io, dm, "Dupes", &.{.{ .from = "Twin", .at = "2026-10-10T08:00:00Z", .body = "which one" }});
    // A topic nobody has written to, and one whose date will not read:
    // each dated by its file, floored to an even second.
    try disk.write(io, a, try chat_paths.transcriptPath(a, dm, "Empty"), "", .{});
    try touch(io, try chat_paths.transcriptPath(a, dm, "Empty"), 1790000001);
    _ = try transcript(a, io, dm, "BadDate", &.{.{ .from = "Debbie", .uid = "2", .at = "yesterday", .body = "when?" }});
    try touch(io, try chat_paths.transcriptPath(a, dm, "BadDate"), 1790000003);
    // A sidecar past 1 KiB, and a quoted, imaged excerpt.
    _ = try transcript(a, io, dm, "Excerpt", &.{.{ .from = "Debbie", .uid = "2", .at = "2026-10-10T09:00:00+02:00", .body = "> quoted\n\n![pic](/x.png)\n\nand   then" }});
    try sidecar(a, io, dm, "Excerpt", "1 {size}\n" ++ &@as([1100]u8, @splat('x')) ++ "\n");

    // A DM Steve is not in, and one with a member he has written nothing to.
    _ = try transcript(a, io, try chat_paths.dmConvDir(a, "2_4"), "Theirs", &.{.{ .from = "Debbie", .uid = "2", .body = "not Steve's" }});

    // A channel Steve is in, and one he is not.
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n", .{});
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "private.channel" }), "2\n", .{});
    _ = try transcript(a, io, try chat_paths.channelConvDir(a, "general"), "Hello", &.{.{ .from = "Debbie", .uid = "2", .at = "2026-10-10T10:00:00Z", .body = "hi all" }});
    _ = try transcript(a, io, try chat_paths.channelConvDir(a, "private"), "Secret", &.{.{ .from = "Debbie", .uid = "2", .body = "hidden" }});

    // Docs: two with valid slugs, one without, and a folder.
    const docs = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "docs" });
    for ([_][]const u8{ "my-notes.md", "reading-list.md", "Bad_Slug.md", "plain.txt" }, 0..) |name, i| {
        const p = try std.fs.path.join(a, &.{ docs, name });
        try disk.write(io, a, p, "body", .{});
        try touch(io, p, 1790000005 + @as(i96, @intCast(i)) * 2);
    }
    try disk.makeDir(io, a, try std.fs.path.join(a, &.{ docs, "folder.md" }));
    // Another member's docs are theirs.
    try disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "2", "docs", "theirs.md" }), "body", .{});

    const page = try harness.UidSite.ask(a, io, "/chat/recent", steve);
    try testing.expectEqualStrings("200 OK", harness.status(page));
    const open = "<script id=\"recent-data\" type=\"application/json\">";
    const from = (std.mem.indexOf(u8, page, open) orelse return error.TestUnexpectedResult) + open.len;
    const json = page[from .. std.mem.indexOfPos(u8, page, from, "</script>") orelse return error.TestUnexpectedResult];
    try testing.expectEqualStrings(want, json);

    // **A CACHE WHOSE READ FAILS IS A MISS** (metal-vmm QUEUE 284): every
    // sidecar's and window's read failing answers as no sidecar at all, and a
    // folder where a sidecar goes the same.
    const chat_router = @import("chat_router.zig");
    chat_router.test_cache_fails = true;
    const failing = try recentJson(a, io, steve);
    chat_router.test_cache_fails = false;
    const sessions = try std.fs.path.join(a, &.{ dm, "sessions" });
    var current_count: []const u8 = "";
    for (try disk.list(io, a, sessions)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".count")) continue;
        const p = try std.fs.path.join(a, &.{ sessions, e.name });
        try disk.remove(io, a, p);
        if (std.mem.eql(u8, e.name, "Current.count")) current_count = p;
    }
    try testing.expect(current_count.len > 0);
    const missing = try recentJson(a, io, steve);
    try testing.expectEqualStrings(missing, failing);
    try testing.expect(!std.mem.eql(u8, want, missing));
    try disk.makeDir(io, a, current_count);
    try testing.expectEqualStrings(missing, try recentJson(a, io, steve));
}

/// /chat/recent's JSON, as `steve` asks for it.
fn recentJson(a: std.mem.Allocator, io: Io, steve: []const u8) ![]const u8 {
    const page = try harness.UidSite.ask(a, io, "/chat/recent", steve);
    try testing.expectEqualStrings("200 OK", harness.status(page));
    const open = "<script id=\"recent-data\" type=\"application/json\">";
    const from = (std.mem.indexOf(u8, page, open) orelse return error.TestUnexpectedResult) + open.len;
    return page[from .. std.mem.indexOfPos(u8, page, from, "</script>") orelse return error.TestUnexpectedResult];
}

/// The JSON for the tree above, newest first: an empty topic, a bad date
/// and an unnamed block dated by their files; docs that are not slugs, a
/// folder, another member's docs, a DM and a channel Steve is not in, left
/// out. Every row but Alone, Nasty, Ahead, FarSize and Reused is what
/// gatherRows and lastMessage answered, the day the Roc took them over; those
/// five are lastMessage's own tests' answers (chat_count.zig, before 277),
/// added with it gone.
const want =
    \\[{"kind":"chat","at":"2026-10-10T15:00:00Z","url":"/chat/c/1_2/Reused","where":"to Debbie","topic":"Reused","excerpt":"from someone since gone","dm":true},{"kind":"chat","at":"2026-10-10T14:00:00Z","url":"/chat/c/1_2/FarSize","who":"Debbie","where":"to Debbie","topic":"FarSize","excerpt":"modest","dm":true},{"kind":"chat","at":"2026-10-10T13:00:00Z","url":"/chat/c/1_2/Ahead","who":"Debbie","where":"to Debbie","topic":"Ahead","excerpt":"the real last","dm":true},{"kind":"chat","at":"2026-10-10T12:00:00Z","url":"/chat/c/1_2/Nasty","who":"Debbie","where":"to Debbie","topic":"Nasty","excerpt":"before ------------- after","dm":true},{"kind":"chat","at":"2026-10-10T11:00:00Z","url":"/chat/c/1_2/Alone","who":"You","where":"to Debbie","topic":"Alone","excerpt":"alone","dm":true},{"kind":"chat","at":"2026-10-10T10:00:00Z","url":"/channel/general/Hello","who":"Debbie","where":"in general","topic":"Hello","excerpt":"hi all"},{"kind":"chat","at":"2026-10-10T08:00:00Z","url":"/chat/c/1_2/Dupes","where":"to Debbie","topic":"Dupes","excerpt":"which one","dm":true},{"kind":"chat","at":"2026-10-10T07:00:00Z","url":"/chat/c/1_2/Excerpt","who":"Debbie","where":"to Debbie","topic":"Excerpt","excerpt":"> quoted [image] and then","dm":true},{"kind":"chat","at":"2026-10-10T07:00:00Z","url":"/chat/c/1_2/Stranger","where":"to Debbie","topic":"Stranger","excerpt":"left","dm":true},{"kind":"chat","at":"2026-10-10T05:00:00Z","url":"/chat/c/1_2/Fallback","who":"Debbie","where":"to Debbie","topic":"Fallback","excerpt":"by name","dm":true},{"kind":"chat","at":"2026-10-10T04:00:00Z","url":"/chat/c/1_2/Wrong","who":"You","where":"to Debbie","topic":"Wrong","excerpt":"b","dm":true},{"kind":"chat","at":"2026-10-10T03:00:00Z","url":"/chat/c/1_2/Full","who":"Debbie","where":"to Debbie","topic":"Full","excerpt":"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl…","dm":true},{"kind":"chat","at":"2026-10-10T02:00:00Z","url":"/chat/c/1_2/Behind","who":"You","where":"to Debbie","topic":"Behind","excerpt":"newer, mine","dm":true},{"kind":"chat","at":"2026-10-10T01:00:00Z","url":"/chat/c/1_2/Current","who":"Debbie","where":"to Debbie","topic":"Current","excerpt":"the record says Debbie","dm":true},{"kind":"chat","at":"2026-09-21T14:13:28Z","url":"/chat/c/1_2/Nameless","where":"to Debbie","topic":"Nameless","dm":true},{"kind":"doc","at":"2026-09-21T14:13:26Z","who":"You","slug":"reading-list","title":"Reading list"},{"kind":"doc","at":"2026-09-21T14:13:24Z","who":"You","slug":"my-notes","title":"My notes"},{"kind":"chat","at":"2026-09-21T14:13:22Z","url":"/chat/c/1_2/BadDate","where":"to Debbie","topic":"BadDate","dm":true},{"kind":"chat","at":"2026-09-21T14:13:20Z","url":"/chat/c/1_2/Empty","where":"to Debbie","topic":"Empty","dm":true}]
;
