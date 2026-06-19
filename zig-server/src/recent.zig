//! recent: /chat/recent — a flat reverse-chronological feed of activity across
//! the signed-in user's chat sessions (DMs + channels) and personal docs. Go's
//! server/chat/recent.go. The initial-load source is file mtime: on every GET
//! the server walks the convs the viewer participates in plus their docs dir,
//! stats each session/doc file, and ships the rows newest-first as inline JSON
//! (the same recentEvent shape the live stream would push, so recent.js uses one
//! row builder for both paint and upsert).
//!
//! Live stream parity gap (honest, documented): Go's /chat/recent/stream pushes
//! one event per write via a per-uid recentBus that Conv.AppendMessage →
//! fanoutMessage feeds (alongside notify/images/code). That cross-page fanout
//! isn't wired into the zig appendMessage yet — it's the shared extension the
//! Images/Code surfaces also need, to be built with them. So here the stream is
//! a keepalive-only stub: the page paints correctly and re-humanizes the "When"
//! column on its own 20s timer, but a new message/doc shows up on RELOAD, not
//! live. recent.js reacts only to real onmessage events, so an idle stream is
//! the correct "nothing happening" (same pattern as the notify/sidebar stubs).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const docs_store = @import("docs_store.zig");
const chat = @import("chat.zig");
const timefmt = @import("timefmt.zig");
const feed = @import("recent_feed.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

const Kind = enum { chat, doc };

/// RecentItem is one row before JSON encoding. `at_ns` (file mtime) is the sort
/// key; `at` is its RFC3339 rendering for the wire. Chat-only fields are
/// pre-resolved per viewer exactly like Go's publishRecentForConv, so DM and
/// channel rows are shaped identically.
const RecentItem = struct {
    kind: Kind,
    at_ns: i96,
    at: []const u8,
    // chat-only
    url: []const u8 = "",
    where: []const u8 = "",
    topic: []const u8 = "",
    last_author: []const u8 = "",
    excerpt: []const u8 = "",
    // doc-only
    slug: []const u8 = "",
    title: []const u8 = "",
};

/// handle dispatches /chat/recent* — `rest` is the path after "/recent" (keeps
/// its leading '/', empty for "/chat/recent"). Go: the page is the exact path,
/// plus /chat/recent/stream; anything else 404s.
/// handle dispatches /chat/recent* — `rest` is the path after "/recent" ("" or
/// "/stream"). Mirrors Go: the page is the exact path plus /chat/recent/stream.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    if (rest.len == 0) return renderRecentPage(req, io, alloc, uid);
    // Live: a per-uid subscriber on the recent bus. The server-rendered page IS
    // the backlog, so the stream is live-only (no replay). Fed by the
    // appendMessage cross-page fanout + docs save/create.
    if (std.mem.eql(u8, rest, "/stream")) {
        return chat.forwardUserStream(req, alloc, bus, try store.recentBusKey(alloc, uid));
    }
    return http.notFound(req);
}

fn renderRecentPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const items = try gatherRecentItems(io, alloc, uid);

    var b: std.ArrayList(u8) = .empty;
    try chat.writeChrome(&b, alloc, "Recent", "Recent", viewer, "recent");
    // Cross-page attention strip + favicon alert on incoming pings (notify.js
    // no-ops when #chat-notify is absent). Recent users camp here, so the tab
    // needs to alert too.
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"recent-mount\"></div>");
    try emitRecentData(&b, alloc, items);
    try b.print(alloc, "<script src=\"/chat/recent.js?v={s}\"></script>" ++
        "<script src=\"/chat/notify.js?v={s}\"></script>", .{ chat.asset_v, chat.asset_v });
    try b.appendSlice(alloc, "</div></body></html>"); // close .app-body-wrap (PageFooter)

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// emitRecentData ships the initial feed as inline JSON next to the mount slot.
/// The `</`→`<\/` pass prevents the JSON from closing the surrounding <script>.
/// Mirrors Go's emitRecentData (one shape for first-paint + live upserts).
fn emitRecentData(b: *std.ArrayList(u8), alloc: Alloc, items: []RecentItem) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (items, 0..) |it, i| {
        if (i != 0) try j.append(alloc, ',');
        try encodeEvent(&j, alloc, it);
    }
    try j.append(alloc, ']');
    const safe = try replaceSeq(alloc, j.items, "</", "<\\/");
    try b.appendSlice(alloc, "<script id=\"recent-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

/// encodeEvent writes one recentEvent JSON object, delegating to the shared
/// recent_feed encoder so the backlog and the live fanout emit one shape.
fn encodeEvent(j: *std.ArrayList(u8), alloc: Alloc, it: RecentItem) !void {
    switch (it.kind) {
        .chat => try feed.encodeChatEvent(j, alloc, it.at, it.url, it.topic, it.where, it.last_author, it.excerpt),
        .doc => try feed.encodeDocEvent(j, alloc, it.at, it.slug, it.title),
    }
}

// ── gather (Go's gatherRecentItems) ───────────────────────────────────────────

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
        const where = try std.fmt.allocPrint(alloc, "with {s}", .{u.name});
        try gatherConvSessions(io, alloc, &items, dir, base, where);
    }

    // Channels the viewer is a member of.
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        const dir = try store.channelConvDir(alloc, name);
        const base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});
        const where = try std.fmt.allocPrint(alloc, "in {s}", .{name});
        try gatherConvSessions(io, alloc, &items, dir, base, where);
    }

    // The viewer's own docs.
    for (try docs_store.listUserDocs(io, alloc, uid)) |d| {
        const path = docs_store.docPath(alloc, uid, d.slug) catch continue;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try items.append(alloc, .{
            .kind = .doc,
            .at_ns = st.mtime.nanoseconds,
            .at = try timefmt.formatRFC3339UTC(alloc, secsOf(st.mtime.nanoseconds)),
            .slug = d.slug,
            .title = d.title,
        });
    }

    const slice = try items.toOwnedSlice(alloc);
    std.mem.sort(RecentItem, slice, {}, newestFirst);
    return slice;
}

/// gatherConvSessions appends a chat row for each session in one conv: stat its
/// mtime, resolve the last author's name from the .lastauthor companion, and
/// build a one-line excerpt of the latest message. `base`/`where` are the conv's
/// pre-resolved URL base and per-viewer context label.
fn gatherConvSessions(io: Io, alloc: Alloc, items: *std.ArrayList(RecentItem), dir: []const u8, base: []const u8, where: []const u8) !void {
    for (try store.listSessions(io, alloc, dir)) |sid| {
        const path = try store.sessionMdPath(alloc, dir, sid);
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try items.append(alloc, .{
            .kind = .chat,
            .at_ns = st.mtime.nanoseconds,
            .at = try timefmt.formatRFC3339UTC(alloc, secsOf(st.mtime.nanoseconds)),
            .url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid }),
            .where = where,
            .topic = sid,
            .last_author = try lastAuthorName(io, alloc, dir, sid),
            .excerpt = try feed.recentExcerpt(alloc, try lastMessageMarkdown(io, alloc, dir, sid)),
        });
    }
}

fn secsOf(ns: i96) i64 {
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

fn newestFirst(_: void, a: RecentItem, b: RecentItem) bool {
    return a.at_ns > b.at_ns;
}

/// lastAuthorName resolves the most-recent author's display name for a session:
/// read the `<sid>.lastauthor` companion uid, map to a name. "" when the
/// companion is missing (pre-companion sessions → recent.js's "New message").
fn lastAuthorName(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.lastauthor", .{sid});
    const path = try std.fs.path.join(alloc, &.{ dir, "sessions", file });
    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return "";
    const auid = std.mem.trim(u8, raw, " \t\r\n");
    if (auid.len == 0) return "";
    return users.getUserName(io, alloc, auid);
}

/// lastMessageMarkdown returns the raw markdown of a session's most recent
/// message, or "" if empty/unreadable. Reads the whole transcript — fine at our
/// scale (the page already stats every session file). Mirrors Go.
fn lastMessageMarkdown(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) ![]const u8 {
    const raw = (try store.rawSession(io, alloc, dir, sid)) orelse return "";
    const msgs = try store.decodeChatFile(alloc, raw);
    if (msgs.len == 0) return "";
    return msgs[msgs.len - 1].markdown;
}

/// replaceSeq returns `input` with every `needle` replaced by `repl` (alloc-owned).
fn replaceSeq(alloc: Alloc, input: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, input, needle, repl);
    const out = try alloc.alloc(u8, n);
    _ = std.mem.replace(u8, input, needle, repl, out);
    return out;
}
