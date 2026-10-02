//! recent: /chat/recent — a flat reverse-chronological feed of activity across
//! the signed-in user's chat sessions (DMs + channels) and personal docs. The
//! initial-load source is file mtime: on every GET the server walks the convs the
//! viewer participates in plus their docs dir, stats each session/doc file, and
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
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const docs_store = @import("docs_store.zig");
const disk = @import("store.zig");
const chat_sse = @import("chat_sse.zig");
const chrome = @import("chat_chrome.zig");
const html = @import("html.zig");
const timefmt = @import("timefmt.zig");
const feed = @import("recent_feed.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

const Kind = enum { chat, doc };

/// RecentItem is one row before JSON encoding. `at_ns` (file mtime) is the sort
/// key; `at` is its RFC3339 rendering for the wire. Chat-only fields are
/// pre-resolved per viewer, so DM and channel rows are shaped identically.
const RecentItem = struct {
    kind: Kind,
    at_ns: i96,
    at: []const u8,
    // who: author display name, already "You" for the viewer (chat + doc).
    who: []const u8 = "",
    // chat-only
    url: []const u8 = "",
    where: []const u8 = "",
    topic: []const u8 = "",
    excerpt: []const u8 = "",
    dm: bool = false, // 1:1 conv (vs channel) — drives the "(DM)" label

    // doc-only
    slug: []const u8 = "",
    title: []const u8 = "",
};

/// handle dispatches /chat/recent* — `rest` is the path after "/recent" ("" or
/// "/stream"); anything else 404s.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    if (rest.len == 0) return renderRecentPage(req, io, alloc, uid);
    // Live: a per-uid subscriber on the recent bus. The server-rendered page IS
    // the backlog, so the stream is live-only (no replay). Fed by the
    // appendMessage cross-page fanout + docs save/create.
    if (std.mem.eql(u8, rest, "/stream")) {
        return chat_sse.forwardUserStream(req, alloc, bus, try store.recentBusKey(alloc, uid));
    }
    return http.notFound(req);
}

fn renderRecentPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const items = try gatherRecentItems(io, alloc, uid);

    var b: std.ArrayList(u8) = .empty;
    try chrome.begin(&b, alloc, "Recent", "Recent", viewer, "recent");
    // Cross-page attention strip + favicon alert on incoming pings (notify.js
    // no-ops when #chat-notify is absent). Recent users camp here, so the tab
    // needs to alert too.
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"recent-mount\"></div>");
    try emitRecentData(&b, alloc, items);
    try b.print(alloc, "<script src=\"/chat/recent.js?v={s}\"></script>" ++
        "<script src=\"/chat/notify.js?v={s}\"></script>", .{ chrome.asset_v, chrome.asset_v });
    try chrome.end(&b, alloc);

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// emitRecentData ships the initial feed as inline JSON next to the mount slot.
/// The `</`→`<\/` pass prevents the JSON from closing the surrounding <script>.
fn emitRecentData(b: *std.ArrayList(u8), alloc: Alloc, items: []RecentItem) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (items, 0..) |it, i| {
        if (i != 0) try j.append(alloc, ',');
        try encodeEvent(&j, alloc, it);
    }
    try j.append(alloc, ']');
    const safe = try html.scriptSafe(alloc, j.items);
    try b.appendSlice(alloc, "<script id=\"recent-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

/// encodeEvent writes one recentEvent JSON object, delegating to the shared
/// recent_feed encoder so the backlog and the live fanout emit one shape.
fn encodeEvent(j: *std.ArrayList(u8), alloc: Alloc, it: RecentItem) !void {
    switch (it.kind) {
        .chat => try feed.encodeChatEvent(j, alloc, it.at, it.url, it.who, it.where, it.topic, it.excerpt, it.dm),
        .doc => try feed.encodeDocEvent(j, alloc, it.at, it.who, it.slug, it.title),
    }
}

// ── gather ───────────────────────────────────────────

/// gatherRecentItems walks every conv that includes the viewer — DMs (every
/// other authorized principal) AND the channels they're a member of — plus their
/// docs dir, statting each file for its mtime. Returned newest-first.
fn gatherRecentItems(io: Io, alloc: Alloc, uid: []const u8) ![]RecentItem {
    var items: std.ArrayList(RecentItem) = .empty;

    // DMs: one conv per other authorized principal.
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, uid)) continue;
        const conv = try store.chatPairKey(alloc, uid, u.id);
        const dir = try store.dmConvDir(alloc, conv);
        const base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv});
        const where = try std.fmt.allocPrint(alloc, "to {s}", .{u.name});
        try gatherConvSessions(io, alloc, &items, dir, base, where, uid, true);
    }

    // Channels the viewer is a member of.
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        const dir = try store.channelConvDir(alloc, name);
        const base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});
        const where = try std.fmt.allocPrint(alloc, "in {s}", .{name});
        try gatherConvSessions(io, alloc, &items, dir, base, where, uid, false);
    }

    // The viewer's own docs.
    for (try docs_store.listUserDocs(io, alloc, uid)) |d| {
        const path = docs_store.docPath(alloc, uid, d.slug) catch continue;
        const st = disk.stat(io, alloc, path) catch continue;
        const secs = fileSeconds(st.mtime);
        try items.append(alloc, .{
            .kind = .doc,
            .at_ns = @as(i96, secs) * std.time.ns_per_s,
            .at = try timefmt.formatRFC3339UTC(alloc, secs),
            .who = "You",
            .slug = d.slug,
            .title = d.title,
        });
    }

    const slice = try items.toOwnedSlice(alloc);
    std.mem.sort(RecentItem, slice, {}, newestFirst);
    return slice;
}

/// gatherConvSessions appends a chat row for each session in one conv: its last
/// message, when it was sent and by whom, and a one-line excerpt of it.
/// `base`/`where` are the conv's pre-resolved URL base and per-viewer context
/// label; `dm` flags a 1:1 conv (vs a channel) for the wire.
///
/// **NEITHER A STAT NOR A TRANSCRIPT READ.** Both were per-session costs that
/// grew with the conversation: this page used to read and decode every
/// transcript in full to take the last message of each. `store.lastMessage`
/// answers from the session's sidecar, and the date it carries is the message's
/// own — which is also the order, so there is no mtime to stat for.
fn gatherConvSessions(io: Io, alloc: Alloc, items: *std.ArrayList(RecentItem), dir: []const u8, base: []const u8, where: []const u8, viewer: []const u8, dm: bool) !void {
    for (try store.listSessions(io, alloc, dir)) |sid| {
        const url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid });
        const last = (try store.lastMessage(io, alloc, dir, sid)) orelse {
            // A session nobody has written to yet: it still belongs on the page.
            try byFileTime(io, alloc, items, dir, sid, url, where, dm);
            continue;
        };
        const at = timefmt.unixFromRFC3339(last.date) orelse {
            // A message whose date header is missing or malformed — a
            // transcript written by something other than this server. Ordering
            // it at the epoch would bury it, and shipping its empty date to
            // the client renders as "NaNd", so it falls back to the file.
            try byFileTime(io, alloc, items, dir, sid, url, where, dm);
            continue;
        };
        try items.append(alloc, .{
            .kind = .chat,
            .at_ns = @as(i96, at) * std.time.ns_per_s,
            // Normalized, so a date written with an offset reads as this
            // server's own do; for those it is the same text.
            .at = try timefmt.formatRFC3339UTC(alloc, at),
            .who = try authorName(io, alloc, dir, sid, viewer, last.uid),
            .url = url,
            .where = where,
            .topic = sid,
            .excerpt = try feed.recentExcerpt(alloc, last.markdown),
            .dm = dm,
        });
    }
}

/// **A FILE'S TIME, AS FAT KEEPS IT: IN EVEN SECONDS.** A row with no
/// recorded date (a doc, a session with no messages, a message whose date
/// will not read) is ordered and shown by its file's modification time. FAT
/// keeps that in two-second steps, rounded down, so a file written at an odd
/// second reads a second earlier on gopher-metal than on Linux, and the two
/// hosts showed the same data differently (gopher-metal's MIGRATION.md,
/// "Rehearsed": 7 sessions). Every host floors it, so they agree.
fn fileSeconds(mtime_ns: i96) i64 {
    const secs: i64 = @intCast(@divFloor(mtime_ns, std.time.ns_per_s));
    return secs - @mod(secs, 2);
}

/// newestFirst orders the feed. **A TIE IS BROKEN BY THE URL**, because a
/// message's date is recorded to the second: two sessions written inside one
/// second must still come out in the same order on every host that serves this
/// data, or the two builds of this application would disagree about a page.
fn newestFirst(_: void, a: RecentItem, b: RecentItem) bool {
    if (a.at_ns != b.at_ns) return a.at_ns > b.at_ns;
    const ka = if (a.url.len > 0) a.url else a.slug;
    const kb = if (b.url.len > 0) b.url else b.slug;
    return std.mem.lessThan(u8, ka, kb);
}

/// byFileTime appends a row ordered by the session file's own mtime, with no
/// excerpt: for a session with no messages, and for one whose last message
/// carries no date this server can read.
fn byFileTime(io: Io, alloc: Alloc, items: *std.ArrayList(RecentItem), dir: []const u8, sid: []const u8, url: []const u8, where: []const u8, dm: bool) !void {
    const path = try store.sessionMdPath(alloc, dir, sid);
    const st = disk.stat(io, alloc, path) catch return;
    const secs = fileSeconds(st.mtime);
    try items.append(alloc, .{
        .kind = .chat,
        .at_ns = @as(i96, secs) * std.time.ns_per_s,
        .at = try timefmt.formatRFC3339UTC(alloc, secs),
        .url = url,
        .where = where,
        .topic = sid,
        .dm = dm,
    });
}

/// authorName renders the most-recent author's display name, "You" when that is
/// the viewer. `uid` is what the session's sidecar recorded; a session written
/// before it recorded one falls back to the `.lastauthor` companion, and ""
/// when neither knows (legacy pre-companion sessions → an empty Who cell).
fn authorName(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8, viewer: []const u8, uid: []const u8) ![]const u8 {
    const auid = if (uid.len > 0) uid else store.lastAuthorUid(io, alloc, dir, sid);
    if (auid.len == 0) return "";
    if (std.mem.eql(u8, auid, viewer)) return "You";
    return users.getUserName(io, alloc, auid);
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
    const md = try store.sessionMdPath(a, dir, "empty");
    try disk.write(io, a, md, "", .{});
    // 2026-09-21T14:13:21Z: an odd second, half a second in.
    const odd: i96 = 1790000001 * std.time.ns_per_s + 500_000_000;
    var f = try std.Io.Dir.cwd().openFile(io, md, .{ .mode = .read_write });
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = odd } } });
    f.close(io);

    var items: std.ArrayList(RecentItem) = .empty;
    try byFileTime(io, a, &items, dir, "empty", "/chat/c/1_2/empty", "to Bob", true);
    try testing.expectEqual(@as(usize, 1), items.items.len);
    try testing.expectEqualStrings(try timefmt.formatRFC3339UTC(a, 1790000000), items.items[0].at);
    try testing.expectEqual(@as(i96, 1790000000) * std.time.ns_per_s, items.items[0].at_ns);
}
