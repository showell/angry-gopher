//! recent: /chat/recent — a flat reverse-chronological feed of activity across
//! the signed-in user's chat topics (DMs + channels) and personal docs. This
//! is its reads (`gatherRows`: the convs the viewer is in, each topic's last
//! message, a file's time where there is no date, their docs) and its
//! stream; the page is the Roc's (roc-webbox chat/main.roc `gather_recent!`), which
//! ships the rows newest-first as inline JSON (the same recentEvent shape the
//! live stream pushes, so recent.js uses one row builder for both paint and
//! upsert).
//!
//! Live stream: /chat/recent/stream is a per-uid subscriber on the recent bus,
//! live-only (the server-rendered page already IS the backlog, so no replay).
//! chat_store.appendMessage fans one event onto the recent bus per write
//! (alongside notify/images/code) and docs save/create do the same, so a new
//! message or doc shows up live. recent.js re-humanizes the "When" column on a
//! 20s timer and upserts rows from onmessage events.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_count = @import("chat_count.zig");
const chat_fanout = @import("chat_fanout.zig");
const Io = @import("host_io").Io;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const docs_store = @import("docs_store.zig");
const disk = @import("webbox").store;
const sse = @import("webbox").sse;
const timefmt = @import("timefmt.zig");
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// **ONE ROW OF THE FEED, AS GATHERED**: what the page is built from, with
/// every read it needs done. `secs` orders the row and dates it: a message's
/// own date, or its file's (in even seconds, below). `uid` is who wrote the
/// topic's last message ("" where the sidecar does not know, or for a row
/// dated by its file), and `name` theirs, read only for someone other than
/// the viewer; a doc's `uid` is the viewer's own. `key` is a chat row's URL
/// or a doc's slug, `label` its "to <name>"/"in <channel>" or the doc's
/// title. The Roc builds the page from these (roc-webbox chat/main.roc
/// `gather_recent!`, chat/Recent.roc): the "You", the excerpt, the order, the JSON.
pub const Row = struct {
    doc: bool = false,
    secs: i64,
    uid: []const u8 = "",
    name: []const u8 = "",
    key: []const u8,
    label: []const u8 = "",
    topic: []const u8 = "",
    markdown: []const u8 = "",
    dm: bool = false,
};

/// handle dispatches /chat/recent* — `rest` is the path after "/recent"; only
/// the stream comes here, the page and the rest being the Roc's.
pub fn handle(req: *Request, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    // Live: a per-uid subscriber on the recent bus. The server-rendered page IS
    // the backlog, so the stream is live-only (no replay). Fed by the
    // appendMessage cross-page fanout + docs save/create.
    if (std.mem.eql(u8, rest, "/stream")) {
        return sse.forward(req, bus, try chat_fanout.recentBusKey(alloc, uid));
    }
    std.debug.panic("recent.handle: {s} is the Roc's", .{rest});
}

// ── gather ───────────────────────────────────────────

/// gatherRows walks every conv that includes the viewer — DMs (every other
/// authorized principal) AND the channels they're a member of — plus their
/// docs dir, in that order.
pub fn gatherRows(io: Io, alloc: Alloc, uid: []const u8) ![]Row {
    var rows: std.ArrayList(Row) = .empty;

    // DMs: one conv per other authorized principal.
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, uid)) continue;
        const conv = try chat_paths.chatPairKey(alloc, uid, u.id);
        const dir = try chat_paths.dmConvDir(alloc, conv);
        const base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv});
        const where = try std.fmt.allocPrint(alloc, "to {s}", .{u.name});
        try gatherConvTopics(io, alloc, &rows, dir, base, where, uid, .dm);
    }

    // Channels the viewer is a member of.
    for (try chat_paths.listUserChannels(io, alloc, uid)) |name| {
        const dir = try chat_paths.channelConvDir(alloc, name);
        const base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});
        const where = try std.fmt.allocPrint(alloc, "in {s}", .{name});
        try gatherConvTopics(io, alloc, &rows, dir, base, where, uid, .channel);
    }

    // The viewer's own docs.
    for (try docs_store.listUserDocs(io, alloc, uid)) |d| {
        const path = docs_store.docPath(alloc, uid, d.slug) catch continue;
        const st = (try disk.statOrNull(io, alloc, path)) orelse continue;
        try rows.append(alloc, .{ .doc = true, .secs = fileSeconds(st.mtime), .uid = uid, .key = d.slug, .label = d.title });
    }
    return rows.toOwnedSlice(alloc);
}

/// gatherConvTopics appends a row for each topic in one conv: its last
/// message, when it was sent and by whom. `base`/`where` are the conv's
/// pre-resolved URL base and per-viewer context label; `kind` says a 1:1
/// conv from a channel, for the wire.
///
/// **NEITHER A STAT NOR A TRANSCRIPT READ.** Both were per-topic costs that
/// grew with the conversation: this page used to read and decode every
/// transcript in full to take the last message of each. `chat_count.lastMessage`
/// answers from the topic's sidecar, and the date it carries is the message's
/// own — which is also the order, so there is no mtime to stat for.
fn gatherConvTopics(io: Io, alloc: Alloc, rows: *std.ArrayList(Row), dir: []const u8, base: []const u8, where: []const u8, viewer: []const u8, kind: store.ConvKind) !void {
    for (try chat_paths.listTopics(io, alloc, dir)) |sid| {
        const url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid });
        const last = (try chat_count.lastMessage(io, alloc, dir, sid)) orelse {
            // A topic nobody has written to yet: it still belongs on the page.
            try byFileTime(io, alloc, rows, dir, sid, url, where, kind);
            continue;
        };
        const at = timefmt.unixFromRFC3339(last.at) orelse {
            // A message whose date header is missing or malformed — a
            // transcript written by something other than this server. Ordering
            // it at the epoch would bury it, and shipping its empty date to
            // the client renders as "NaNd", so it falls back to the file.
            try byFileTime(io, alloc, rows, dir, sid, url, where, kind);
            continue;
        };
        try rows.append(alloc, .{
            .secs = at,
            .uid = last.uid,
            .name = try authorName(io, alloc, viewer, last.uid),
            .key = url,
            .label = where,
            .topic = sid,
            .markdown = last.markdown,
            .dm = kind == .dm,
        });
    }
}

/// **A FILE'S TIME, AS FAT KEEPS IT: IN EVEN SECONDS.** A row with no
/// recorded date (a doc, a topic with no messages, a message whose date
/// will not read) is ordered and shown by its file's modification time. FAT
/// keeps that in two-second steps, rounded down, so a file written at an odd
/// second reads a second earlier on zig-metal-unikernel than on Linux, and the two
/// hosts showed the same data differently (zig-metal-unikernel's MIGRATION.md,
/// "Rehearsed": 7 sessions). Every host floors it, so they agree.
fn fileSeconds(mtime_ns: i96) i64 {
    const secs: i64 = @intCast(@divFloor(mtime_ns, std.time.ns_per_s));
    return secs - @mod(secs, 2);
}

/// byFileTime appends a row dated by the topic file's own mtime, with no
/// author and no message: for a topic with no messages, and for one whose
/// last message carries no date this server can read.
fn byFileTime(io: Io, alloc: Alloc, rows: *std.ArrayList(Row), dir: []const u8, sid: []const u8, url: []const u8, where: []const u8, kind: store.ConvKind) !void {
    const path = try chat_paths.transcriptPath(alloc, dir, sid);
    const st = (try disk.statOrNull(io, alloc, path)) orelse return;
    try rows.append(alloc, .{ .secs = fileSeconds(st.mtime), .key = url, .label = where, .topic = sid, .dm = kind == .dm });
}

/// authorName reads the most-recent author's display name, for someone other
/// than the viewer ("" for the viewer, whom the page calls "You", and where
/// the sidecar does not know: an empty Who cell, never an older author,
/// which could be a "You" the viewer did not write, zig-metal-unikernel
/// 153(1)).
fn authorName(io: Io, alloc: Alloc, viewer: []const u8, uid: []const u8) ![]const u8 {
    if (uid.len == 0 or std.mem.eql(u8, uid, viewer)) return "";
    return users.getUserName(io, alloc, uid);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a file's time is floored to an even second, as FAT keeps it" {
    try testing.expectEqual(@as(i64, 1790000000), fileSeconds(1790000000 * std.time.ns_per_s));
    try testing.expectEqual(@as(i64, 1790000000), fileSeconds(1790000001 * std.time.ns_per_s + 999_999_999));
    try testing.expectEqual(@as(i64, 1790000002), fileSeconds(1790000002 * std.time.ns_per_s + 1));
}

test "fs: a session with no messages, written at an odd second, shows the even second before it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "chat", "1_2" });
    const md = try chat_paths.transcriptPath(a, dir, "empty");
    try disk.write(io, a, md, "", .{});
    // 2026-09-21T14:13:21Z: an odd second, half a second in.
    const odd: i96 = 1790000001 * std.time.ns_per_s + 500_000_000;
    var f = try std.Io.Dir.cwd().openFile(io, md, .{ .mode = .read_write });
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = odd } } });
    f.close(io);

    var rows: std.ArrayList(Row) = .empty;
    try byFileTime(io, a, &rows, dir, "empty", "/chat/c/1_2/empty", "to Bob", .dm);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqual(@as(i64, 1790000000), rows.items[0].secs);
}
