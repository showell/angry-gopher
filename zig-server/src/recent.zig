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
const chat_sse = @import("chat_sse.zig");
const chrome = @import("chrome.zig");
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
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try items.append(alloc, .{
            .kind = .doc,
            .at_ns = st.mtime.nanoseconds,
            .at = try timefmt.formatRFC3339UTC(alloc, secsOf(st.mtime.nanoseconds)),
            .who = "You",
            .slug = d.slug,
            .title = d.title,
        });
    }

    const slice = try items.toOwnedSlice(alloc);
    std.mem.sort(RecentItem, slice, {}, newestFirst);
    return slice;
}

/// gatherConvSessions appends a chat row for each session in one conv: stat its
/// mtime, resolve the last author ("You" for the viewer) from the .lastauthor
/// companion, and build a one-line excerpt of the latest message. `base`/`where`
/// are the conv's pre-resolved URL base and per-viewer context label; `dm` flags
/// a 1:1 conv (vs a channel) for the wire.
fn gatherConvSessions(io: Io, alloc: Alloc, items: *std.ArrayList(RecentItem), dir: []const u8, base: []const u8, where: []const u8, viewer: []const u8, dm: bool) !void {
    for (try store.listSessions(io, alloc, dir)) |sid| {
        const path = try store.sessionMdPath(alloc, dir, sid);
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try items.append(alloc, .{
            .kind = .chat,
            .at_ns = st.mtime.nanoseconds,
            .at = try timefmt.formatRFC3339UTC(alloc, secsOf(st.mtime.nanoseconds)),
            .who = try lastAuthorName(io, alloc, dir, sid, viewer),
            .url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid }),
            .where = where,
            .topic = sid,
            .excerpt = try feed.recentExcerpt(alloc, try lastMessageMarkdown(io, alloc, dir, sid)),
            .dm = dm,
        });
    }
}

fn secsOf(ns: i96) i64 {
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

fn newestFirst(_: void, a: RecentItem, b: RecentItem) bool {
    return a.at_ns > b.at_ns;
}

/// lastAuthorName resolves the most-recent author's display name for a session,
/// rendered "You" when the author is the viewer: read the `<sid>.lastauthor`
/// companion uid, map to a name. "" when the companion is missing (legacy
/// pre-companion sessions → an empty Who cell).
fn lastAuthorName(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8, viewer: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.lastauthor", .{sid});
    const path = try std.fs.path.join(alloc, &.{ dir, "sessions", file });
    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return "";
    const auid = std.mem.trim(u8, raw, " \t\r\n");
    if (auid.len == 0) return "";
    if (std.mem.eql(u8, auid, viewer)) return "You";
    return users.getUserName(io, alloc, auid);
}

/// lastMessageMarkdown returns the raw markdown of a session's most recent
/// message, or "" if empty/unreadable. Reads the whole transcript — fine at our
/// scale (the page already stats every session file).
fn lastMessageMarkdown(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) ![]const u8 {
    const raw = (try store.rawSession(io, alloc, dir, sid)) orelse return "";
    const msgs = try store.decodeChatFile(alloc, raw);
    if (msgs.len == 0) return "";
    return msgs[msgs.len - 1].markdown;
}

