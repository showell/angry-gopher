//! chat_fanout: a stored message, out to everyone who should see it: the
//! topic's live stream and every member's cross-page surfaces (notify, sidebar,
//! recent, images, code), each failure counted (metal-vmm QUEUE 156(c), 172;
//! split from chat_store.zig by 174).

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const bus_mod = @import("webbox").bus;
const Bus = bus_mod.Bus;
const users = @import("users.zig");
const recent_feed = @import("recent_feed.zig");
const images_store = @import("images_store.zig");
const code_store = @import("code_store.zig");
const testing = std.testing;
const chat_store = @import("chat_store.zig");
const appendMessage = chat_store.appendMessage;
const ChatMessage = chat_store.ChatMessage;
const CountFixture = chat_store.CountFixture;
const ConvMeta = chat_store.ConvMeta;

/// recentBusKey / imagesBusKey are the per-uid bus keys for the cross-page
/// streams. Namespaced so they can't collide with the per-conv "<key>/<sid>"
/// stream keys. Builder lives here (the publisher) so the stream handlers
/// subscribe with the SAME function — no string drift.
pub fn recentBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "rec:{s}", .{uid});
}

pub fn imagesBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "img:{s}", .{uid});
}

pub fn codeBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "code:{s}", .{uid});
}

/// notifyBusKey / sidebarBusKey are the per-uid keys for the two cross-page
/// attention streams.
/// Namespaced like the recent/images/code keys so nothing collides.
pub fn notifyBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "ntf:{s}", .{uid});
}

pub fn sidebarBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "sb:{s}", .{uid});
}

/// convKeyBaseURL returns the URL root for a conv addressed by its storage key.
/// DM keys contain '_' (channel names exclude it), a sufficient discriminator.
pub fn convKeyBaseURL(alloc: Alloc, conv_key: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, conv_key, '_') != null) {
        return std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv_key});
    }
    return std.fmt.allocPrint(alloc, "/channel/{s}", .{conv_key});
}

/// The fan-out's failures since boot: a surface that failed for one member
/// (metal-vmm QUEUE 156(c)). Said on /admin/host (`fanoutText`), with the
/// last one named: the route table has no stderr of its own.
pub var fanout_failures: usize = 0;

var fanout_last_buf: [192]u8 = undefined;

var fanout_last: []const u8 = "";

/// A fan-out step that failed, counted and said.
pub fn fanoutFailed(surface: []const u8, who: []const u8, e: anyerror, conv_key: []const u8, sid: []const u8) void {
    fanout_failures += 1;
    fanout_last = std.fmt.bufPrint(&fanout_last_buf, "{s} for member {s}, {s}, on {s}/{s}", .{ surface, who, @errorName(e), conv_key, sid }) catch surface;
}

/// The fan-out's failures as /admin/host shows them.
pub fn fanoutText(alloc: Alloc) ![]const u8 {
    if (fanout_failures == 0) return "none";
    return std.fmt.allocPrint(alloc, "{d}; the last: {s}", .{ fanout_failures, fanout_last });
}

/// fanoutCrossPage publishes one new message to every cross-page attention feed
///: notify (status strip), recent (Recent page), images /
/// code (per-user transcripts) per member, plus a sidebar topic-added on the
/// session's FIRST message (index == 0). Best-effort: the message is saved
/// before; a failure for one member's surface is counted and said, and never
/// blocks the write or that member's other surfaces.
pub fn fanoutCrossPage(io: Io, alloc: Alloc, bus: *Bus, meta: ConvMeta, conv_key: []const u8, sid: []const u8, msg: ChatMessage, from_id: []const u8, index: usize) void {
    // What every surface shares: a failure here is counted, never a surface
    // skipped in silence (metal-vmm QUEUE 172: images and code, durable and
    // with no rebuild, were lost uncounted).
    const base = convKeyBaseURL(alloc, conv_key) catch |e| return fanoutFailed("every surface", "every member", e, conv_key, sid);
    const rec_url = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid }) catch |e| return fanoutFailed("every surface", "every member", e, conv_key, sid);
    const excerpt = recent_feed.recentExcerpt(alloc, msg.markdown);
    const tags = images_store.extractImageTags(alloc, msg.markdown);
    const blocks = code_store.extractCodeBlocks(alloc, msg.markdown);
    const src_url = images_store.imagesSourceURL(alloc, base, msg.id);

    // notify text is viewer-invariant (rec_url is the per-conv topic URL, the
    // notify-strip link). DMs read "X sent you a message on <sid>."; channels
    // read "X posted to <key> > <sid>."
    const notify_text = if (meta.kind == .channel)
        std.fmt.allocPrint(alloc, "{s} posted to {s} > {s}.", .{ msg.from, conv_key, sid })
    else
        std.fmt.allocPrint(alloc, "{s} sent you a message on {s}.", .{ msg.from, sid });
    // topic-added (sidebar) — only on the session's first message; viewer-invariant.
    const topic_added: Alloc.Error![]const u8 = if (index == 0)
        std.fmt.allocPrint(alloc, "{{\"kind\":\"topic-added\",\"conv\":{f},\"sid\":{f},\"url\":{f}}}", .{
            std.json.fmt(conv_key, .{}), std.json.fmt(sid, .{}), std.json.fmt(rec_url, .{}),
        })
    else
        "";

    const fan = Fan{
        .io = io,
        .alloc = alloc,
        .bus = bus,
        .meta = meta,
        .conv_key = conv_key,
        .sid = sid,
        .msg = msg,
        .from_id = from_id,
        .rec_url = rec_url,
        .src_url = src_url,
        .excerpt = excerpt,
        .tags = tags,
        .blocks = blocks,
        .notify_text = notify_text,
        .topic_added = topic_added,
    };
    // **ONE SURFACE AT A TIME** (metal-vmm QUEUE 156(c)): a failure costs
    // that member that surface and is said; it never skips their others (a
    // `catch continue` on images lost their code, which is durable and has
    // no rebuild).
    for (meta.members) |uid| {
        inline for (.{ "notify", "sidebar", "recent", "images", "code" }) |surface| {
            @field(Fan, surface)(&fan, uid) catch |e| fanoutFailed(surface, uid, e, conv_key, sid);
        }
    }
}

/// One message's fan-out, a function per surface, each failing alone.
const Fan = struct {
    io: Io,
    alloc: Alloc,
    bus: *Bus,
    meta: ConvMeta,
    conv_key: []const u8,
    sid: []const u8,
    msg: ChatMessage,
    from_id: []const u8,
    rec_url: []const u8,
    // What each surface needs, or why it could not be had: the surfaces
    // that need it fail, counted, one member at a time.
    src_url: Alloc.Error![]const u8,
    excerpt: @typeInfo(@TypeOf(recent_feed.recentExcerpt)).@"fn".return_type.?,
    tags: @typeInfo(@TypeOf(images_store.extractImageTags)).@"fn".return_type.?,
    blocks: @typeInfo(@TypeOf(code_store.extractCodeBlocks)).@"fn".return_type.?,
    notify_text: Alloc.Error![]const u8,
    topic_added: Alloc.Error![]const u8,

    /// Every member EXCEPT the author is pinged. The favicon dot means "a
    /// partner did something"; you don't notify yourself about your own
    /// message (the author already sees the self-confirm via the main feed
    /// echo). Skipping the author here is the real invariant — the open-feed
    /// conv+session suppression in notify.js only covers the currently-viewed
    /// thread, so author-skip is what keeps the dot quiet when you send to a
    /// thread you're not actively staring at.
    fn notify(f: *const Fan, uid: []const u8) !void {
        if (std.mem.eql(u8, uid, f.from_id)) return;
        var nj: std.ArrayList(u8) = .empty;
        try nj.print(f.alloc, "{{\"conv\":{f},\"session\":{f},\"text\":{f},\"link_url\":{f}}}", .{
            std.json.fmt(f.conv_key, .{}),        std.json.fmt(f.sid, .{}),
            std.json.fmt(try f.notify_text, .{}), std.json.fmt(f.rec_url, .{}),
        });
        f.bus.publish(try notifyBusKey(f.alloc, uid), nj.items);
    }

    /// topic-added to every member on the first message only.
    fn sidebar(f: *const Fan, uid: []const u8) !void {
        const topic_added = try f.topic_added;
        if (topic_added.len == 0) return;
        f.bus.publish(try sidebarBusKey(f.alloc, uid), topic_added);
    }

    /// Every member sees the row (sender included). `who` renders "You" for
    /// the recipient who authored it; everyone else sees the name.
    fn recent(f: *const Fan, uid: []const u8) !void {
        // absent-ok: the recent feed's "where" label only; the row itself is sent.
        const where = recentWhere(f.io, f.alloc, f.meta, f.conv_key, uid) catch "";
        const who = if (std.mem.eql(u8, uid, f.from_id)) "You" else f.msg.from;
        var rj: std.ArrayList(u8) = .empty;
        try recent_feed.encodeChatEvent(&rj, f.alloc, .{ .at = f.msg.date, .url = f.rec_url, .who = who, .where = where, .topic = f.sid, .excerpt = try f.excerpt, .dm = f.meta.kind == .dm });
        f.bus.publish(try recentBusKey(f.alloc, uid), rj.items);
    }

    /// Only when the message carried <img> tags.
    fn images(f: *const Fan, uid: []const u8) !void {
        const tags = try f.tags;
        if (tags.len == 0) return;
        const e = images_store.ImagesEntry{ .source_id = f.msg.id, .from = f.msg.from, .conv = f.conv_key, .at = f.msg.date, .images = tags };
        try images_store.appendImagesEntry(f.io, f.alloc, uid, e);
        var ij: std.ArrayList(u8) = .empty;
        try images_store.encodeImagesEvent(&ij, f.alloc, e, try f.src_url);
        f.bus.publish(try imagesBusKey(f.alloc, uid), ij.items);
    }

    /// Only when the message carried fenced code blocks.
    fn code(f: *const Fan, uid: []const u8) !void {
        const blocks = try f.blocks;
        if (blocks.len == 0) return;
        const e = code_store.CodeEntry{ .source_id = f.msg.id, .from = f.msg.from, .conv = f.conv_key, .at = f.msg.date, .blocks = blocks };
        try code_store.appendCodeEntry(f.io, f.alloc, uid, e);
        var cj: std.ArrayList(u8) = .empty;
        try code_store.encodeCodeEvent(&cj, f.alloc, e, try f.src_url);
        f.bus.publish(try codeBusKey(f.alloc, uid), cj.items);
    }
};

/// recentWhere is the per-recipient context label the What column reads as
/// "message <where> (<topic>)": a channel names itself ("in <name>"); a DM names
/// the OTHER party ("to <name>").
fn recentWhere(io: Io, alloc: Alloc, meta: ConvMeta, conv_key: []const u8, viewer: []const u8) ![]const u8 {
    if (meta.kind == .channel) return std.fmt.allocPrint(alloc, "in {s}", .{conv_key});
    var other: []const u8 = "";
    for (meta.members) |m| {
        if (!std.mem.eql(u8, m, viewer)) other = m;
    }
    const name = try users.getUserName(io, alloc, other);
    return std.fmt.allocPrint(alloc, "to {s}", .{name});
}

test "the fan-out's surfaces fail one at a time, each said: a member's images that will not write still leave their code (metal-vmm QUEUE 156(c))" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    // Member 2's images.md is a folder: its write fails.
    try Io.Dir.cwd().createDirPath(f.io, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "2", "images.md" }));
    const before = fanout_failures;
    const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{ "1", "2" } };
    _ = try appendMessage(f.io, a, &f.bus, meta, .{ .dir = f.dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "1" }, "<img src=\"/x.png\">\n\n```\ncode\n```", "");
    try testing.expectEqual(before + 1, fanout_failures);
    try testing.expect(std.mem.startsWith(u8, fanout_last, "images for member 2, "));
    const code = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "2", "code.md" });
    try testing.expect((try Io.Dir.cwd().readFileAlloc(f.io, code, a, .limited(4096))).len > 0);
    // And member 1's surfaces are whole.
    _ = try Io.Dir.cwd().readFileAlloc(f.io, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "images.md" }), a, .limited(4096));
}
