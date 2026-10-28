//! chat: the chat conversation surface. It serves the prod client — the embedded
//! chat/*.js bundles — over the on-disk chat tree (chat_store.chat_root). The
//! client boots, paints the transcript from the SSE backlog, sends messages, and
//! receives them live.
//!
//! Routes:
//!   GET  /chat                         resume: your last conversation (serveChatDefault),
//!                                      or the empty-state page
//!   GET  /chat/default, /chat/conversations, /chat/msg/<id>   (see route below)
//!   GET  /chat/<file>.js               an embedded client bundle (colors.js, …)
//!   GET  /chat/c/<conv>                303 → its default topic
//!   GET  /chat/c/<conv>/<sid>          the conversation page (boots the prod JS)
//!   GET  /chat/c/<conv>/<sid>/stream   SSE: backlog replay + LIVE fan-out
//!   POST /chat/c/<conv>/<sid>/send     post a message (fans out to live streams)
//!   GET  /chat/c/<conv>/<sid>/raw      the literal on-disk .md bytes
//!   GET  /chat/c/<conv>/<sid>/reactions  the reaction sidecar (ndjson; reactions.zig)
//!   POST /chat/c/<conv>/<sid>/react    toggle one reaction (fans out as event: reaction)
//!   .../<sid>/{upload,uploads,download,pin,unpin,saved}   see routeTopic
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
const reactions = @import("reactions.zig");
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// Max bytes for one posted message.
const max_message_bytes = limits.body.chat_message;

// Resolved-conversation domain types (Conv, Topic) live in chat_conv.zig — shared
// with the page renderer (chat_page.zig) so neither side re-discriminates kind.
const Conv = @import("chat_conv.zig").Conv;
const Topic = @import("chat_conv.zig").Topic;

// ── dispatch ───────────────────────────────────────────────────────────────

/// handle dispatches /chat/* — `sub` keeps its leading '/' (empty for "/chat").
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    // Embedded JS assets are public (the prod server serves them unauthenticated
    // too — they're static client code); resolve them before the identity gate.
    if (sub.len > 1 and std.mem.endsWith(u8, sub, ".js")) {
        return serveAsset(req, sub[1..]);
    }

    // The request's time, read once: everything it stamps carries it
    // (request_time.zig).
    const now = Now.read(io);
    const uid = try users.loadCurrentUserID(io, alloc, req);
    // NEED_PASSWORD: the whole chat subsystem (DMs, docs, recent, images, code,
    // the conversations API) is members + agents only. A guest (name-only, no
    // password) or a stranger is sent to set a password and returned here —
    // guests may play the game, but chat requires membership.
    if (!try users.isPrincipalAuthorized(io, alloc, uid)) {
        return toLogin(req, alloc, "/chat", sub);
    }

    // Presence: any authorized page/action counts as activity — but NOT the SSE
    // streams (a stream is the browser's job, and JS assets resolved above). On
    // the offline→online edge this fans a came-online event to other users.
    if (!isStreamPath(sub)) presence.markActiveAndBroadcast(io, alloc, bus, uid, now);

    // Bare /chat is no longer a conversations INDEX — it resumes you straight
    // into your last conversation (serveChatDefault), or shows the empty-state page if
    // you have none. Every "Chat" link across the site points here, so the resume
    // behaviour is centralized in one handler.
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        return serveChatDefault(req, io, alloc, uid, now);
    }
    // /chat/docs[/...] — the three-pane authoring surface (docs.zig). Guard the
    // boundary so only "/docs" or "/docs/..." matches (".js" is already served
    // above; anything like "/docsX" falls through to 404).
    if (matchPrefix(sub, "/docs")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try docs.handle(req, io, alloc, bus, uid, rest, now);
            return;
        }
    }
    // /chat/recent[/stream] — the activity feed (recent.zig).
    if (matchPrefix(sub, "/recent")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try recent.handle(req, io, alloc, bus, uid, rest);
            return;
        }
    }
    // /chat/images[/stream] — the per-user image transcript (images.zig).
    if (matchPrefix(sub, "/images")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try images.handle(req, io, alloc, bus, uid, rest);
            return;
        }
    }
    // /chat/code[/stream] — the per-user code transcript (code.zig).
    if (matchPrefix(sub, "/code")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try code.handle(req, io, alloc, bus, uid, rest);
            return;
        }
    }
    // /chat/links — a per-user curated links page (chat_links.zig). Static: no stream.
    if (matchPrefix(sub, "/links")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try links.handle(req, io, alloc, uid, rest);
            return;
        }
    }
    // /chat/search/words, /chat/search/messages — search across every
    // conversation the viewer can see (chat_search.zig), JSON.
    if (matchPrefix(sub, "/search")) |rest| return chat_search.handle(req, io, alloc, uid, rest, now);
    // /chat/default — resume the last (conv, topic); /chat/conversations —
    // the (partner × topic) matrix as JSON (the API-key discovery entry point);
    // /chat/msg/<id> — resolve a global MSG_ ref to its thread and 302 there.
    if (std.mem.eql(u8, sub, "/default")) return serveChatDefault(req, io, alloc, uid, now);
    if (std.mem.eql(u8, sub, "/conversations")) return serveConversations(req, io, alloc, uid, now);
    if (matchPrefix(sub, "/msg/")) |id| return redirectToMsg(req, io, alloc, uid, id);
    if (matchPrefix(sub, "/c/")) |rest| {
        try routeConv(req, io, alloc, bus, uid, rest, now);
        return;
    }
    // The two cross-page attention streams the prod JS opens on boot. Both are
    // per-uid bus subscribers forwarding the published event JSON verbatim
    // (notify: status-strip pings + came-online; sidebar: topic-added +
    // user-online). Live-only — the server-rendered page is the backlog.
    if (std.mem.eql(u8, sub, "/notifications")) {
        return sse.forward(req, bus, try chat_fanout.notifyBusKey(alloc, uid));
    }
    if (std.mem.eql(u8, sub, "/sidebar/stream")) {
        return sse.forward(req, bus, try chat_fanout.sidebarBusKey(alloc, uid));
    }
    try http.notFound(req);
}

/// handleChannel dispatches /channel/* — `sub` is the path after "/channel".
pub fn handleChannel(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    const now = Now.read(io);
    const uid = try users.loadCurrentUserID(io, alloc, req);
    // NEED_PASSWORD: channels are members + agents only (same gate as /chat).
    if (!try users.isPrincipalAuthorized(io, alloc, uid)) {
        return toLogin(req, alloc, "/channel", sub);
    }
    if (!isStreamPath(sub)) presence.markActiveAndBroadcast(io, alloc, bus, uid, now);

    var segs = segments(sub);
    const name_raw = segs.next() orelse return http.notFound(req);
    if (!chat_paths.validChannelName(name_raw)) return http.notFound(req);
    // No dupe: the router resolved the path via http.target, which owns it, so
    // path-derived slices already survive the body read.
    const name = name_raw;

    // **ONE ANSWER, THAT SAYS WHY** (metal-vmm QUEUE 156(j)): a channel that
    // is not there and one the viewer is not in (or was removed from) read
    // alike, so the page names no channel a viewer cannot see.
    const not_yours = try std.fmt.allocPrint(alloc, "#{s} is not a channel you are a member of.", .{name});
    const members = (try chat_paths.readChannelMembers(io, alloc, name)) orelse return page.serveNotFoundPage(req, io, alloc, uid, not_yours, "/chat");
    if (!chat_paths.hasMember(members, uid)) return page.serveNotFoundPage(req, io, alloc, uid, not_yours, "/chat");

    const conv = Conv{
        .meta = .{ .kind = .channel, .members = members },
        .key = name,
        .base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name}),
        .dir = try chat_paths.channelConvDir(alloc, name),
    };

    const topic_raw = segs.next() orelse {
        const def = try chat_paths.findFirstTopic(io, alloc, conv.dir);
        if (def.len == 0) {
            // Member of a channel with no topics yet — offer to start the first.
            const title = try std.fmt.allocPrint(alloc, "#{s}", .{name});
            return page.serveNoTopicsPage(req, io, alloc, uid, conv.base, title);
        }
        return http.redirect(req, try http.Target.format(alloc, "{s}/{s}", .{ conv.base, def }));
    };
    // /channel/<name>/new — create a topic ("new" is reserved).
    if (std.mem.eql(u8, topic_raw, "new")) return createTopic(req, io, alloc, bus, conv, uid, now);
    if (!chat_paths.validTopicID(topic_raw)) return http.notFound(req);
    const topic = topic_raw; // owned via the router's http.target (see `name` above)

    const title = try std.fmt.allocPrint(alloc, "#{s}: {s}", .{ name, topic });
    try routeTopic(req, io, alloc, bus, &segs, uid, Topic{ .conv = conv, .sid = topic, .title = title }, now);
}

/// routeConv handles /chat/c/<conv>[/<sid>[/raw|stream|send]]. `rest` is after "/c/".
fn routeConv(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8, now: Now) !void {
    var segs = segments(rest);
    const pair_raw = segs.next() orelse return http.notFound(req);
    if (!try chat_paths.chatKeyParticipant(alloc, pair_raw, uid)) return http.notFound(req);
    // No dupe: the router resolved the path via http.target, which owns it, so
    // these path-derived strings (used after the body read for response URLs,
    // fanout keys, member uids) already survive head invalidation.
    const pair = pair_raw;

    // DM members are the two uids in the (already participant-checked) pair key.
    const us = std.mem.indexOfScalar(u8, pair, '_').?;
    // The other half must be an account: a DM is between two people, and its
    // folder and the fan-out's writes are named after both.
    const other = if (std.mem.eql(u8, pair[0..us], uid)) pair[us + 1 ..] else pair[0..us];
    if (!try users.hasPrincipal(io, alloc, other)) return http.notFound(req);
    const conv = Conv{
        .meta = try store.ConvMeta.dm(alloc, pair[0..us], pair[us + 1 ..]),
        .key = pair,
        .base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{pair}),
        .dir = try chat_paths.dmConvDir(alloc, pair),
    };

    const sid_raw = segs.next() orelse {
        const def = try chat_paths.findFirstTopic(io, alloc, conv.dir);
        if (def.len == 0) {
            // Addressable pair, no topics yet — offer to start the first one
            // (rather than 404 a real, reachable conversation).
            const partner = try loadPartnerName(io, alloc, conv.key, uid);
            const title = try std.fmt.allocPrint(alloc, "Chat w/{s}", .{partner});
            return page.serveNoTopicsPage(req, io, alloc, uid, conv.base, title);
        }
        return http.redirect(req, try http.Target.format(alloc, "{s}/{s}", .{ conv.base, def }));
    };
    // /chat/c/<conv>/new — create a topic ("new" beats {sid}; it's reserved).
    if (std.mem.eql(u8, sid_raw, "new")) return createTopic(req, io, alloc, bus, conv, uid, now);
    if (!chat_paths.validTopicID(sid_raw)) return http.notFound(req);
    const sid = sid_raw; // owned via the router's http.target (see `pair` above)

    const partner = try loadPartnerName(io, alloc, conv.key, uid);
    const title = try std.fmt.allocPrint(alloc, "Chat w/{s}: {s}", .{ partner, sid });
    try routeTopic(req, io, alloc, bus, &segs, uid, Topic{ .conv = conv, .sid = sid, .title = title }, now);
}

/// routeTopic fans out the per-topic tail shared by DMs and channels: the bare
/// page, `/stream` (SSE), `/send` (POST a message), or `/raw` (literal bytes).
/// `segs` is positioned just after the sid. `title` is the top-bar title.
fn routeTopic(req: *Request, io: Io, alloc: Alloc, bus: *Bus, segs: *SegIter, uid: []const u8, topic: Topic, now: Now) !void {
    const conv = topic.conv;
    // **A TOPIC THAT IS NOT THERE IS A 404 THAT SAYS SO** (metal-vmm QUEUE
    // 156(j)), where its page was served as an empty one and became where
    // /chat/default resumes. Every tail but `send`, which makes a topic as
    // its first message does (the judges send to one first). Without case,
    // as Steve's rule has it (2026-10-02, option 1: case does not tell
    // topics apart, on FAT or on Linux).
    var peek = segs.*;
    const is_send = if (peek.next()) |t| std.mem.eql(u8, t, "send") else false;
    if (!is_send and !try hasTopic(io, alloc, conv.dir, topic.sid)) {
        const what = try std.fmt.allocPrint(alloc, "There is no topic \u{201C}{s}\u{201D} in this conversation.", .{topic.sid});
        return page.serveNotFoundPage(req, io, alloc, uid, what, conv.base);
    }
    const tail = segs.next() orelse {
        if (!isRead(req)) return http.methodNotAllowed(req, .GET);
        try page.serveConversationPage(req, io, alloc, uid, topic, now);
        return;
    };
    // /uploads/<file> — serve a stored image (two trailing segments).
    if (std.mem.eql(u8, tail, "uploads")) {
        const file = segs.next() orelse return http.notFound(req);
        if (segs.next() != null) return http.notFound(req);
        if (!isRead(req)) return http.methodNotAllowed(req, .GET);
        return upload.serveUpload(req, io, alloc, conv.dir, topic.sid, file);
    }
    if (segs.next() != null) return http.notFound(req); // the rest take no further segment
    if (std.mem.eql(u8, tail, "stream")) {
        try chat_sse.streamTranscript(req, io, alloc, bus, .{ .dir = conv.dir, .key = conv.key, .sid = topic.sid });
    } else if (std.mem.eql(u8, tail, "send")) {
        try sendMessage(req, io, alloc, bus, topic, uid, now);
    } else if (std.mem.eql(u8, tail, "upload")) {
        try upload.handleUpload(req, io, alloc, uid, conv.dir, conv.base, topic.sid);
    } else if (std.mem.eql(u8, tail, "pin")) {
        try pinTopic(req, io, alloc, uid, conv.key, topic.sid, true);
    } else if (std.mem.eql(u8, tail, "unpin")) {
        try pinTopic(req, io, alloc, uid, conv.key, topic.sid, false);
    } else if (std.mem.eql(u8, tail, "raw")) {
        if (!isRead(req)) return http.methodNotAllowed(req, .GET);
        try serveRawTranscript(req, io, alloc, conv.dir, topic.sid);
    } else if (std.mem.eql(u8, tail, "download")) {
        if (!isRead(req)) return http.methodNotAllowed(req, .GET);
        try download.serveBundle(req, io, alloc, conv.dir, topic.sid);
    } else if (std.mem.eql(u8, tail, "saved")) {
        if (!isRead(req)) return http.methodNotAllowed(req, .GET);
        try serveSavedIds(req, io, alloc, uid, conv.key, topic.sid);
    } else if (std.mem.eql(u8, tail, "reactions")) {
        try reactions.serveFile(req, io, alloc, conv.dir, topic.sid);
    } else if (std.mem.eql(u8, tail, "react")) {
        try reactions.handleReact(req, io, alloc, bus, conv.dir, conv.key, topic.sid, uid, now);
    } else {
        try http.notFound(req);
    }
}

/// Whether `req` only reads: a GET, or a HEAD (std answers it without the
/// body). The page and the tails that serve what is stored answer nothing
/// else: a POST there was served as if it were a GET.
fn isRead(req: *const Request) bool {
    return req.head.method == .GET or req.head.method == .HEAD;
}

fn hasTopic(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !bool {
    for (try chat_paths.listTopics(io, alloc, conv_dir)) |s| {
        if (std.ascii.eqlIgnoreCase(s, sid)) return true;
    }
    return false;
}

/// serveSavedIds answers GET /<conv>/<sid>/saved → JSON array of the message ids the
/// caller has saved to their reading list within this topic, for the page to
/// mark its bubbles. Served from reading_list's mtime-cached parse.
fn serveSavedIds(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8) !void {
    const ids = try reading_list.loadSavedIds(io, alloc, uid, conv_key, sid);
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
    const back = try http.Target.format(alloc, "{s}/{s}", .{ conv.base, topic.sid });
    _ = try store.appendMessage(io, alloc, bus, now, conv.meta, .{ .dir = conv.dir, .key = conv.key, .sid = topic.sid }, .{ .name = from_name, .id = uid }, md, cid);
    return sendDone(req, is_async, back);
}

/// pinTopic handles POST /<…>/<sid>/{pin,unpin}: toggle
/// whether `sid` is in the caller's per-conv Pinned group, then 204. Per-user
/// state; conv-level auth already passed (any participant pins their own view).
fn pinTopic(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8, pinned: bool) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    try chat_state.setTopicPinned(io, alloc, uid, conv_key, sid, pinned);
    return req.respond("", .{ .status = .no_content });
}

/// sendDone reports a send: 204 for async fetch callers, else a
/// 303 back to the topic page (the no-JS form-post fallback).
/// The answer to a stored send: allocates nothing, so a send stored is never
/// answered 500 for memory (177.1).
fn sendDone(req: *Request, is_async: bool, back: http.Target) !void {
    if (is_async) return req.respond("", .{ .status = .no_content });
    return http.redirect(req, back);
}

// ── new topic ─────────────────────────────────────────────────────────────────

/// createTopic handles POST <conv-base>/new:
/// validate the `topic` form field, refuse duplicates + the reserved "new", then
/// seed the topic with a first "hi" message (which fans out topic-added). For a
/// DM it also remembers the new topic as last-viewed and announces it as a link
/// in the highest generalN topic, where the partner already watches. Returns
/// `{conv, sid}` JSON. Shared by DMs and channels (kind gates the DM-only extras).
fn createTopic(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv: Conv, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);

    const body = (try http.readLimitedBody(req, alloc, max_message_bytes)) orelse return;
    const topic_raw = (try formField(alloc, body, "topic")) orelse "";
    const topic = std.mem.trim(u8, topic_raw, " \t\r\n");
    if (!chat_paths.validTopicID(topic)) {
        return req.respond("Topic must be letters, digits, and hyphens only — no spaces, underscores, or punctuation.\n", .{ .status = .bad_request });
    }
    if (std.ascii.eqlIgnoreCase(topic, "new")) {
        return req.respond("\"new\" is reserved — pick another topic name.\n", .{ .status = .bad_request });
    }
    // **WITHOUT CASE** (metal-vmm QUEUE 156(a)): the store's names are not
    // (FAT folds them), so "plans" beside "Plans" was one file, the new
    // topic's first message landing in the old.
    for (try chat_paths.listTopics(io, alloc, conv.dir)) |s| {
        if (std.ascii.eqlIgnoreCase(s, topic)) return req.respond("That topic already exists.\n", .{ .status = .conflict });
    }

    const from_name = try users.getUserName(io, alloc, uid);
    // The bookmark first, as a send's (156(g)): one that fails makes no topic,
    // where it answered 500 for a topic made, and a retry met 409. A bookmark
    // to a topic not made is never followed (resumeTopic).
    if (conv.persistsCursor()) try chat_state.setLastViewedTopic(io, alloc, uid, conv.key, topic);
    _ = try store.appendMessage(io, alloc, bus, now, conv.meta, .{ .dir = conv.dir, .key = conv.key, .sid = topic }, .{ .name = from_name, .id = uid }, "hi", "");

    if (conv.persistsCursor()) {
        // Announce the new topic where the partner already watches (best-effort).
        if (try findHighestGeneralTopic(io, alloc, conv.dir)) |gen| {
            if (!std.mem.eql(u8, gen, topic)) {
                const note = try std.fmt.allocPrint(alloc, "New topic: [{s}]({s}/{s})", .{ topic, conv.base, topic });
                // **NOT BEST-EFFORT ANY MORE.** This used to be `catch {}`, so
                // a partner could simply never hear about a topic and nobody
                // would ever know why. The host logs what it is handed and
                // closes the connection; a retry then meets the duplicate
                // check above and says the topic already exists, which is true
                // and is a great deal more use than silence.
                _ = try store.appendMessage(io, alloc, bus, now, conv.meta, .{ .dir = conv.dir, .key = conv.key, .sid = gen }, .{ .name = from_name, .id = uid }, note, "");
            }
        }
    }

    const out = try std.fmt.allocPrint(alloc, "{{\"conv\":{f},\"sid\":{f}}}", .{ std.json.fmt(conv.key, .{}), std.json.fmt(topic, .{}) });
    try req.respond(out, .{ .extra_headers = &.{http.json_ct} });
}

/// findHighestGeneralTopic returns the "general<N>" topic with the largest N in
/// `dir`, or null when there is none.
fn findHighestGeneralTopic(io: Io, alloc: Alloc, dir: []const u8) !?[]const u8 {
    var best: ?[]const u8 = null;
    var best_n: i64 = -1;
    for (try chat_paths.listTopics(io, alloc, dir)) |s| {
        if (!std.mem.startsWith(u8, s, "general")) continue;
        const n = decimal.parseInt(i64, s["general".len..]) orelse continue;
        if (n > best_n) {
            best_n = n;
            best = s;
        }
    }
    return best;
}

// ── default / conversations / msg-ref lookup ──────────────────────────────────

/// serveChatDefault resumes the viewer's last conversation: read their last-conv
/// bookmark, resolve its landing topic, and 302 into /chat/c/<conv>/<sid>. It
/// backs both bare /chat and /chat/default. When there's no bookmark (or it names
/// a conv they no longer participate in), we render the "no conversations" page
/// rather than redirect — the invariant that everyone has SOME conversation isn't
/// enforced yet, so this is the honest empty state.
fn serveChatDefault(req: *Request, io: Io, alloc: Alloc, uid: []const u8, now: Now) !void {
    const conv = try chat_state.readLastUserConv(io, alloc, uid);
    if (conv.len == 0 or !(try chat_paths.chatKeyParticipant(alloc, conv, uid))) {
        return page.serveNoConversationsPage(req, io, alloc, uid);
    }
    // A conversation with no topic yet lands on its own page, which offers to
    // start the first, where it went to today's date as a topic: a send makes
    // one there, but a page of a topic not there is a 404 (156(j)'s review).
    if ((try chat_paths.findFirstTopic(io, alloc, try chat_paths.dmConvDir(alloc, conv))).len == 0) {
        return http.redirect(req, try http.Target.format(alloc, "/chat/c/{s}", .{conv}));
    }
    const sid = try chat_state.resumeTopic(io, alloc, uid, conv, now);
    return http.redirect(req, try http.Target.format(alloc, "/chat/c/{s}/{s}", .{ conv, sid }));
}

/// serveConversations serves GET /chat/conversations: the (partner × topic)
/// matrix as JSON — every other authorized principal, each conv's default
/// landing topic and its topic list (sorted). The discovery entry point for
/// API-key clients.
fn serveConversations(req: *Request, io: Io, alloc: Alloc, uid: []const u8, now: Now) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);

    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "{{\"me\":{f},\"conversations\":[", .{std.json.fmt(uid, .{})});
    var first = true;
    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        const conv = try chat_paths.chatPairKey(alloc, uid, partner.id);
        const def = try chat_state.resumeTopic(io, alloc, uid, conv, now);
        const dir = try chat_paths.dmConvDir(alloc, conv);
        try b.print(alloc, "{{\"conv\":{f},\"partner\":{{\"id\":{f},\"name\":{f}}},\"default\":{f},\"sessions\":[", .{
            std.json.fmt(conv, .{}), std.json.fmt(partner.id, .{}), std.json.fmt(partner.name, .{}), std.json.fmt(def, .{}),
        });
        var sfirst = true;
        for (try chat_paths.listTopics(io, alloc, dir)) |s| {
            if (!sfirst) try b.append(alloc, ',');
            sfirst = false;
            try b.print(alloc, "{f}", .{std.json.fmt(s, .{})});
        }
        try b.appendSlice(alloc, "]}");
    }
    try b.appendSlice(alloc, "]}");
    try req.respond(b.items, .{ .extra_headers = &.{http.json_ct} });
}

/// redirectToMsg resolves a global MSG_<id> to the thread it lives in and 302s to
/// that topic URL + #msg-<id>. Walks the viewer's accessible convs (DM partners,
/// then channels) and picks the first whose topic list holds the sid embedded
/// in the id.
fn redirectToMsg(req: *Request, io: Io, alloc: Alloc, uid: []const u8, id: []const u8) !void {
    if (!chat_paths.validMsgRefID(id)) return http.notFound(req);
    const cut = std.mem.lastIndexOfScalar(u8, id, '_').?; // validMsgRefID guarantees one
    const sid = id[0..cut];

    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        const conv = try chat_paths.chatPairKey(alloc, uid, partner.id);
        const dir = try chat_paths.dmConvDir(alloc, conv);
        if (try hasTopicExactly(io, alloc, dir, sid)) {
            return redirectFound(req, try http.Target.format(alloc, "/chat/c/{s}/{s}#msg-{s}", .{ conv, sid, id }));
        }
    }
    for (try chat_paths.listUserChannels(io, alloc, uid)) |name| {
        const dir = try chat_paths.channelConvDir(alloc, name);
        if (try hasTopicExactly(io, alloc, dir, sid)) {
            return redirectFound(req, try http.Target.format(alloc, "/channel/{s}/{s}#msg-{s}", .{ name, sid, id }));
        }
    }
    return http.notFound(req);
}

/// hasTopicExactly reports whether `dir`'s topic list contains `sid`.
fn hasTopicExactly(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) !bool {
    for (try chat_paths.listTopics(io, alloc, dir)) |s| {
        if (std.mem.eql(u8, s, sid)) return true;
    }
    return false;
}

/// To the login page, to come back to `base` `sub` after: **the request's
/// own path, so one that is no path on this site is its 400.** Every other
/// redirect this file builds is from a conversation's base and a topic's
/// sid, which the store's names keep on the site, so its error.NotOnSite is
/// the router's 500: a bug, never a redirect to somewhere else.
fn toLogin(req: *Request, alloc: Alloc, comptime base: []const u8, sub: []const u8) !void {
    const back = http.Target.format(alloc, "/login/full?next=" ++ base ++ "{s}", .{sub}) catch |e| switch (e) {
        error.NotOnSite => return req.respond("not a path on this site\n", .{ .status = .bad_request }),
        else => return e,
    };
    return http.redirect(req, back);
}

/// redirectFound issues a 302 to `location` — the msg-ref
/// lookup uses 302 (a transient lookup-then-go), not the 303 the others use.
fn redirectFound(req: *Request, location: http.Target) !void {
    return http.redirectWith(req, location, .{ .status = .found });
}

// ── raw + index ──────────────────────────────────────────────────────────────

/// serveRawTranscript serves the literal on-disk .md bytes (text/plain, nosniff).
fn serveRawTranscript(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
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

fn loadPartnerName(io: Io, alloc: Alloc, conv: []const u8, me: []const u8) ![]const u8 {
    const us = std.mem.indexOfScalar(u8, conv, '_') orelse return conv;
    const a = conv[0..us];
    const b = conv[us + 1 ..];
    const other = if (std.mem.eql(u8, a, me)) b else a;
    const name = try users.getUserName(io, alloc, other);
    return if (name.len == 0) other else name;
}

const SegIter = struct {
    rest: []const u8,
    fn next(self: *SegIter) ?[]const u8 {
        while (self.rest.len > 0 and self.rest[0] == '/') self.rest = self.rest[1..];
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, '/') orelse self.rest.len;
        const seg = self.rest[0..end];
        self.rest = self.rest[end..];
        return seg;
    }
};

fn segments(path: []const u8) SegIter {
    return .{ .rest = path };
}

fn matchPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

/// isStreamPath reports whether `sub` is one of the chat subsystem's SSE streams
/// — which presence deliberately doesn't count as activity.
/// True for the per-conv/recent/images/code "…/stream" tails,
/// the named "/notifications", and "/sidebar/stream" (caught by the suffix).
fn isStreamPath(sub: []const u8) bool {
    return std.mem.endsWith(u8, sub, "/stream") or std.mem.eql(u8, sub, "/notifications");
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
