//! chat: the chat conversation surface. It serves the prod client — the embedded
//! chat/*.js bundles — over the on-disk chat tree (chat_store.chat_root). The
//! client boots, paints the transcript from the SSE backlog, sends messages, and
//! receives them live.
//!
//! Routes:
//!   GET  /chat                         resume: your last conversation (chatDefault),
//!                                      or the empty-state page
//!   GET  /chat/default, /chat/conversations, /chat/msg/<id>   (see route below)
//!   GET  /chat/<file>.js               an embedded client bundle (colors.js, …)
//!   GET  /chat/c/<conv>                303 → its default topic
//!   GET  /chat/c/<conv>/<sid>          the conversation page (boots the prod JS)
//!   GET  /chat/c/<conv>/<sid>/stream   SSE: backlog replay + LIVE fan-out
//!   POST /chat/c/<conv>/<sid>/send     post a message (fans out to live streams)
//!   GET  /chat/c/<conv>/<sid>/raw      the literal on-disk .md bytes
//!   .../<sid>/{upload,uploads,download,saved}   see topicRoute
//!   .../<sid>/{reactions,react,pin,unpin}   the Roc's (roc-webbox chat/main.roc
//!                                      `act!`, over chat_router.zig's hosted
//!                                      functions and `findTopic` here)
//!   {GET,POST} /channel/<name>/<topic>{,/stream,/send,/raw}   the channel equivalents
//!   GET  /chat/notifications           SSE: per-uid notify strip (status pings +
//!                                      came-online), a notifyBusKey subscriber
//!   GET  /chat/sidebar/stream          SSE: per-uid sidebar upserts (topic-added +
//!                                      user-online), a sidebarBusKey subscriber
//!
//! Live delivery: a /send append publishes a fan-out blob to bus.zig, and every
//! open /stream on the same conv/sid drains it — so a sent message appears live
//! in every open tab. The notify / sidebar / recent / images / code fan-out and
//! presence are likewise in-process (in-memory, lost on restart).
//!
//! Access: member-or-/login/full; DM participant gate; channel membership gate;
//! opaque 404 (no existence leak); sid path-traversal guard.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_fanout = @import("chat_fanout.zig");
const Now = @import("request_time.zig").Now;
const decimal = @import("decimal.zig");
const limits = @import("limits.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");
const html = @import("webbox").html;
// Escaping lives in html.zig, not here, so chat_chrome.zig and the non-chat
// pages (login, game, admin, …) escape without importing the chat dispatcher.
const htmlEscape = html.htmlEscape; // internal alias; the impl lives in html.zig
const chrome = @import("chat_chrome.zig");
const page = @import("chat_page.zig");
const chat_sse = @import("chat_sse.zig");
const sse = @import("webbox").sse;
const edge = @import("webbox").edge;
const docs = @import("docs.zig");
const reading_list = @import("reading_list.zig");
const recent = @import("recent.zig");
const chat_search = @import("chat_search.zig");
const images = @import("images.zig");
const code = @import("code.zig");
const links = @import("chat_links.zig");
const upload = @import("chat_upload.zig");
const presence = @import("presence.zig");
const chat_state = @import("chat_state.zig");
const download = @import("chat_download.zig");
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// Max bytes for one posted message.
const max_message_bytes = limits.body.chat_message;

// Resolved-conversation domain types (Conv, Topic) live in chat_conv.zig — shared
// with the page renderer (chat_page.zig) so neither side re-discriminates kind.
const Conv = @import("chat_conv.zig").Conv;
const Topic = @import("chat_conv.zig").Topic;

// ── serving a route ───────────────────────────────────────────────────────

const roc_chat = @import("roc_chat");
const Route = roc_chat.Route;

/// serve answers a /chat or /channel request where the Roc router sent it
/// (chat_router.zig, which ran the prelude: the static scripts, the gate,
/// presence). `route` is the path as the router parsed it; nothing here
/// reads the path again. What needs the disk or the viewer is decided here,
/// in the order it always was: whether the viewer is in the DM and its
/// other half exists, a channel's members, whether the topic exists, a
/// read-only tail's method.
pub fn serve(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, route: Route, now: Now) !void {
    switch (route.family) {
        // Embedded JS assets are public (static client code): the router
        // sends them here before the gate.
        .asset => return serveAsset(req, route.rest),
        // Bare /chat resumes you straight into your last conversation, or
        // shows the empty-state page if you have none; every "Chat" link
        // across the site points here.
        // /chat, the conversations, a message's link: the Roc's (roc-webbox
        // chat/main.roc), served before Zig is reached.
        .default, .conversations, .msg => std.debug.panic("chat.serve: {t} is the Roc's", .{route.family}),
        // /chat/docs[/...]: the three-pane authoring surface (docs.zig).
        .docs => return docs.handle(req, io, alloc, bus, uid, route.rest, now),
        // /chat/recent, /images, /code [/stream]: the activity feed and the
        // per-user transcripts; /chat/links, a static page.
        .recent => return recent.handle(req, io, alloc, bus, uid, route.rest),
        .images => return images.handle(req, io, alloc, bus, uid, route.rest),
        .code => return code.handle(req, io, alloc, bus, uid, route.rest),
        .links => return links.handle(req, io, alloc, uid, route.rest),
        // /chat/search/words, /chat/search/messages (chat_search.zig), JSON.
        .search => return chat_search.handle(req, io, alloc, uid, route.rest, now),
        .dm => return convRoute(req, io, alloc, bus, uid, route, now),
        .channel => return channelRoute(req, io, alloc, bus, uid, route, now),
        // The two cross-page attention streams the prod JS opens on boot,
        // per-uid bus subscribers forwarding the published event JSON
        // verbatim (notify: status-strip pings + came-online; sidebar:
        // topic-added + user-online). Live-only: the server-rendered page is
        // the backlog.
        .notifications => return sse.forward(req, bus, try chat_fanout.notifyBusKey(alloc, uid)),
        .sidebar_stream => return sse.forward(req, bus, try chat_fanout.sidebarBusKey(alloc, uid)),
        .not_found => return http.notFound(req),
    }
}

/// **A CONVERSATION THE VIEWER MAY USE, AS THE ROC'S HOSTED FUNCTIONS ASK**:
/// where it is, its key and URL base, its kind and, for a channel, its
/// members. `title` is the page's (empty until a topic's is known).
pub const Found = struct {
    dir: []const u8,
    key: []const u8,
    base: []const u8,
    dm: bool,
    members: []const []const u8 = &.{},
    sid: []const u8 = "",
    title: []const u8 = "",

    pub fn address(f: Found) store.TopicAddress {
        return .{ .dir = f.dir, .key = f.key, .sid = f.sid };
    }

    /// The routed conversation the page renderer takes.
    pub fn topic(f: Found, alloc: Alloc) !Topic {
        const us = std.mem.indexOfScalar(u8, f.key, '_') orelse 0;
        const meta: store.ConvMeta = if (f.dm) try store.ConvMeta.dm(alloc, f.key[0..us], f.key[us + 1 ..]) else .{ .kind = .channel, .members = f.members };
        return .{ .conv = .{ .meta = meta, .key = f.key, .base = f.base, .dir = f.dir }, .sid = f.sid, .title = f.title };
    }
};

/// **THE CONVERSATION OF A DM OR CHANNEL ROUTE, IF IT IS THE VIEWER'S**
/// (the Roc's `Host.landing!` and `Host.topic!`): what convRoute and
/// channelRoute look up first, in their order, answering nothing. Null for
/// any of their 404s: the Roc hands the route back, and they answer it.
pub fn findConv(io: Io, alloc: Alloc, uid: []const u8, family: roc_chat.Family, key: []const u8) !?Found {
    switch (family) {
        .dm => {
            if (!try chat_paths.chatKeyParticipant(alloc, key, uid)) return null;
            const us = std.mem.indexOfScalar(u8, key, '_').?;
            const other = if (std.mem.eql(u8, key[0..us], uid)) key[us + 1 ..] else key[0..us];
            if (!try users.principalExists(io, alloc, other)) return null;
            return .{ .dir = try chat_paths.dmConvDir(alloc, key), .key = key, .base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{key}), .dm = true };
        },
        .channel => {
            const members = (try chat_paths.channelMembers(io, alloc, key)) orelse return null;
            if (!chat_paths.hasMember(members, uid)) return null;
            return .{ .dir = try chat_paths.channelConvDir(alloc, key), .key = key, .base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{key}), .dm = false, .members = members };
        },
        else => unreachable,
    }
}

/// A conversation's title, as its pages show it: "Chat w/<partner>" or
/// "#<name>" (reading the partner's name).
pub fn convTitle(io: Io, alloc: Alloc, uid: []const u8, f: Found) ![]const u8 {
    if (f.dm) return std.fmt.allocPrint(alloc, "Chat w/{s}", .{try partnerName(io, alloc, f.key, uid)});
    return std.fmt.allocPrint(alloc, "#{s}", .{f.key});
}

/// **WHERE A TOPIC ROUTE'S TOPIC IS, IF IT IS ONE THE VIEWER MAY USE**
/// (the Roc's `Host.topic!`): `findConv`, the topic's title (the partner's
/// name read, as convRoute reads it), then whether topicRoute would find
/// the topic. Null for any of their 404s.
pub fn findTopic(io: Io, alloc: Alloc, uid: []const u8, route: Route) !?Found {
    std.debug.assert(route.part == .topic);
    var f = (try findConv(io, alloc, uid, route.family, route.key)) orelse return null;
    f.sid = route.sid;
    f.title = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ try convTitle(io, alloc, uid, f), route.sid });
    if (!try topicExists(io, alloc, f.dir, route.sid)) return null;
    return f;
}

/// channelRoute serves /channel/<name>[/<sid>[/...]]: `route.key` is a
/// valid channel name (the router checked its shape).
fn channelRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, route: Route, now: Now) !void {
    const name = route.key;
    // **ONE ANSWER, THAT SAYS WHY** (metal-vmm QUEUE 156(j)): a channel that
    // is not there and one the viewer is not in (or was removed from) read
    // alike, so the page names no channel a viewer cannot see.
    const not_yours = try std.fmt.allocPrint(alloc, "#{s} is not a channel you are a member of.", .{name});
    const members = (try chat_paths.channelMembers(io, alloc, name)) orelse return page.notFoundPage(req, io, alloc, uid, not_yours, "/chat");
    if (!chat_paths.hasMember(members, uid)) return page.notFoundPage(req, io, alloc, uid, not_yours, "/chat");

    const conv = Conv{
        .meta = .{ .kind = .channel, .members = members },
        .key = name,
        .base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name}),
        .dir = try chat_paths.channelConvDir(alloc, name),
    };
    switch (route.part) {
        // The Roc's (roc-webbox chat/main.roc), handed back only when
        // `findConv` did not find it, which was answered above.
        .landing => std.debug.panic("chat: a conversation's landing is the Roc's, and it was here", .{}),
        // A new topic: the Roc's, handed back only when `findConv` did not
        // find the conversation, which was answered above.
        .new => std.debug.panic("chat: a new topic is the Roc's, and its conversation was here", .{}),
        .invalid => return http.notFound(req),
        .topic => {
            const title = try std.fmt.allocPrint(alloc, "#{s}: {s}", .{ name, route.sid });
            return topicRoute(req, io, alloc, bus, route, uid, Topic{ .conv = conv, .sid = route.sid, .title = title }, now);
        },
    }
}

/// convRoute serves /chat/c/<conv>[/<sid>[/...]]: `route.key` is the pair
/// as written.
fn convRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, route: Route, now: Now) !void {
    const pair = route.key;
    if (!try chat_paths.chatKeyParticipant(alloc, pair, uid)) return http.notFound(req);

    // DM members are the two uids in the (already participant-checked) pair key.
    const us = std.mem.indexOfScalar(u8, pair, '_').?;
    // The other half must be an account: a DM is between two people, and its
    // folder and the fan-out's writes are named after both.
    const other = if (std.mem.eql(u8, pair[0..us], uid)) pair[us + 1 ..] else pair[0..us];
    if (!try users.principalExists(io, alloc, other)) return http.notFound(req);
    const conv = Conv{
        .meta = try store.ConvMeta.dm(alloc, pair[0..us], pair[us + 1 ..]),
        .key = pair,
        .base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{pair}),
        .dir = try chat_paths.dmConvDir(alloc, pair),
    };
    switch (route.part) {
        // The Roc's (roc-webbox chat/main.roc), handed back only when
        // `findConv` did not find it, which was answered above.
        .landing => std.debug.panic("chat: a conversation's landing is the Roc's, and it was here", .{}),
        // A new topic: the Roc's, handed back only when `findConv` did not
        // find the conversation, which was answered above.
        .new => std.debug.panic("chat: a new topic is the Roc's, and its conversation was here", .{}),
        .invalid => return http.notFound(req),
        .topic => {
            const partner = try partnerName(io, alloc, conv.key, uid);
            const title = try std.fmt.allocPrint(alloc, "Chat w/{s}: {s}", .{ partner, route.sid });
            return topicRoute(req, io, alloc, bus, route, uid, Topic{ .conv = conv, .sid = route.sid, .title = title }, now);
        },
    }
}

/// topicRoute serves the per-topic tail shared by DMs and channels: the bare
/// page, `/stream` (SSE), `/send` (POST a message), `/raw` (literal bytes),
/// and the rest. `title` is the top-bar title.
fn topicRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, route: Route, uid: []const u8, topic: Topic, now: Now) !void {
    const conv = topic.conv;
    // **A TOPIC THAT IS NOT THERE IS A 404 THAT SAYS SO** (metal-vmm QUEUE
    // 156(j)), where its page was served as an empty one and became where
    // /chat/default resumes. Every tail but `send`, which makes a topic as
    // its first message does (the judges send to one first). Without case,
    // as Steve's rule has it (2026-10-02, option 1: case does not tell
    // topics apart, on FAT or on Linux).
    const is_send = route.tail == .send or route.tail == .invalid_send;
    if (!is_send and !try topicExists(io, alloc, conv.dir, topic.sid)) {
        const what = try std.fmt.allocPrint(alloc, "There is no topic \u{201C}{s}\u{201D} in this conversation.", .{topic.sid});
        return page.notFoundPage(req, io, alloc, uid, what, conv.base);
    }
    switch (route.tail) {
        .page => std.debug.panic("chat.topicRoute: the page is the Roc's, and its topic was here", .{}),
        // /uploads/<file>: serve a stored image.
        .uploads => {
            if (!isRead(req)) return http.methodNotAllowed(req, .GET);
            return upload.serveUpload(req, io, alloc, conv.dir, topic.sid, route.rest);
        },
        .stream => try chat_sse.streamTranscript(req, io, alloc, bus, .{ .dir = conv.dir, .key = conv.key, .sid = topic.sid }),
        .send => try sendMessage(req, io, alloc, bus, topic, uid, now),
        .upload => try upload.handleUpload(req, io, alloc, uid, conv.dir, conv.base, topic.sid),
        // The Roc's (roc-webbox chat/main.roc `act!`, docs/ROC-CHAT.md C4):
        // it hands one back only when `findTopic` did not find it, and that
        // was answered above.
        .pin, .unpin, .reactions, .react => std.debug.panic("chat.topicRoute: {t} is the Roc's, and its topic was here", .{route.tail}),
        .raw => {
            if (!isRead(req)) return http.methodNotAllowed(req, .GET);
            try rawTranscript(req, io, alloc, conv.dir, topic.sid);
        },
        .download => {
            if (!isRead(req)) return http.methodNotAllowed(req, .GET);
            try download.serveBundle(req, io, alloc, conv.dir, topic.sid);
        },
        .saved => {
            if (!isRead(req)) return http.methodNotAllowed(req, .GET);
            try savedIds(req, io, alloc, uid, conv.key, topic.sid);
        },
        // No tail served here, or one with segments after it.
        .invalid, .invalid_send => try http.notFound(req),
    }
}

/// Whether `req` only reads: a GET, or a HEAD (std answers it without the
/// body). The page and the tails that serve what is stored answer nothing
/// else: a POST there was served as if it were a GET.
fn isRead(req: *const Request) bool {
    return req.head.method == .GET or req.head.method == .HEAD;
}

fn topicExists(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !bool {
    for (try chat_paths.listTopics(io, alloc, conv_dir)) |s| {
        if (std.ascii.eqlIgnoreCase(s, sid)) return true;
    }
    return false;
}

/// savedIds answers GET /<conv>/<sid>/saved → JSON array of the message ids the
/// caller has saved to their reading list within this topic, for the page to
/// mark its bubbles. Served from reading_list's mtime-cached parse.
fn savedIds(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8) !void {
    const ids = try reading_list.savedIdsFor(io, alloc, uid, conv_key, sid);
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '[');
    for (ids, 0..) |id, i| {
        if (i != 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(id, .{})}));
    }
    try out.append(alloc, ']');
    try req.respond(out.items, .{ .extra_headers = &.{http.json_ct} });
}

// ── send (write path) ────────────────────────────────────────────────────────

/// sendMessage handles POST /<…>/<sid>/send: parse the markdown+cid form, then
/// append (which fans out live to
/// every open stream on this conv/sid), and report. `X-Chat-Async: 1` → 204;
/// a plain form post → 303 back to the topic.
///
/// **A SEND STORES WHAT WAS SENT, OR IS REFUSED** (metal-vmm QUEUE 156(b)):
/// no `markdown` field, or one that is only whitespace, is a 400, where it
/// answered success having stored nothing; the text is stored as sent (a
/// trim, once, stripped a code block's first indentation), and trimmed only
/// to ask whether it is empty. (`DROP_ON_FLOOR`, which dropped a real
/// message that began with it, is gone: nothing used it.)
fn sendMessage(req: *Request, io: Io, alloc: Alloc, bus: *Bus, topic: Topic, uid: []const u8, now: Now) !void {
    const conv = topic.conv;
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);

    // Read headers BEFORE the body: reading the request body advances the
    // std.http.Server reader past `received_head`, after which iterateHeaders
    // asserts. So capture X-Chat-Async first, then drain the body.
    const is_async = if (try http.header(req, alloc, "x-chat-async")) |v| std.mem.eql(u8, v, "1") else false;

    const body = (try http.readLimitedBody(req, alloc, max_message_bytes)) orelse return;
    const md = (try formField(alloc, body, "markdown")) orelse
        return req.respond("not sent: no message (the form has no markdown field)\n", .{ .status = .bad_request });
    const cid = (try formField(alloc, body, "cid")) orelse "";
    if (std.mem.trim(u8, md, " \t\r\n").len == 0) {
        return req.respond("not sent: the message is empty\n", .{ .status = .bad_request });
    }
    // **A MESSAGE IS TEXT**: its bytes are UTF-8. Stored otherwise, every
    // stream would send it as JSON's array of numbers where the client reads a
    // string. A browser always sends UTF-8; only a hand-made request is refused.
    if (!std.unicode.utf8ValidateSlice(md)) {
        return req.respond("not sent: the message is not UTF-8 text\n", .{ .status = .bad_request });
    }

    // Refuse hostile / absurdly over-formatted markdown at the door rather than
    // store it: fail loud to the author (a 400) instead of fanning out content
    // that every reader would render as the malformed placeholder anyway.
    if (try markdown.hostileReason(alloc, md)) |_| {
        return edge.reject(req, .malformed_markdown, "not sent: malformed markdown — too much formatting; break it into smaller messages\n");
    }

    const from_name = try users.getUserName(io, alloc, uid);
    // The bookmark first (metal-vmm QUEUE 156(g)): one that fails is a 500
    // with nothing stored, never a 500 for a message that was, which the
    // client would send again.
    if (conv.persistsCursor()) try chat_state.setLastViewedTopic(io, alloc, uid, conv.key, topic.sid);
    // Where a plain form post goes back to, made before the store (177.1):
    // made after, an allocation that failed was a 500 for a stored message.
    const back = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv.base, topic.sid });
    _ = try store.appendMessage(io, alloc, bus, now, conv.meta, .{ .dir = conv.dir, .key = conv.key, .sid = topic.sid }, .{ .name = from_name, .id = uid }, md, cid);
    return sendDone(req, is_async, back);
}

/// sendDone reports a send: 204 for async fetch callers, else a
/// 303 back to the topic page (the no-JS form-post fallback).
/// The answer to a stored send: allocates nothing, so a send stored is never
/// answered 500 for memory (177.1).
fn sendDone(req: *Request, is_async: bool, back: []const u8) !void {
    if (is_async) return req.respond("", .{ .status = .no_content });
    return http.redirect(req, back);
}

// ── raw + index ──────────────────────────────────────────────────────────────

/// rawTranscript serves the literal on-disk .md bytes (text/plain, nosniff).
fn rawTranscript(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    const data = (try chat_paths.readTranscript(io, alloc, conv_dir, sid)) orelse return http.notFound(req);
    try req.respond(data, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

/// serveAsset serves an embedded client bundle by file name (no leading slash).
fn serveAsset(req: *Request, name: []const u8) !void {
    for (chrome.assets) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            return http.serveEmbedded(req, a.body, http.js_ct);
        }
    }
    return http.notFound(req);
}

// ── small helpers ─────────────────────────────────────────────────────────────

fn partnerName(io: Io, alloc: Alloc, conv: []const u8, me: []const u8) ![]const u8 {
    const us = std.mem.indexOfScalar(u8, conv, '_') orelse return conv;
    const a = conv[0..us];
    const b = conv[us + 1 ..];
    const other = if (std.mem.eql(u8, a, me)) b else a;
    const name = try users.getUserName(io, alloc, other);
    return if (name.len == 0) other else name;
}

/// formField pulls one application/x-www-form-urlencoded field from `body`,
/// percent/plus-decoded, or null when absent. Field names here ("markdown",
/// "cid") are literal, so only the value is decoded.
pub fn formField(alloc: Alloc, body: []const u8, name: []const u8) !?[]const u8 {
    return http.formField(alloc, body, name);
}

/// urlDecode is `http.formDecode`: one decoder for every form.
pub fn urlDecode(alloc: Alloc, s: []const u8) ![]u8 {
    return http.formDecode(alloc, s);
}
