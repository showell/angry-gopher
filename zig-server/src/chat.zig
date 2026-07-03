//! chat: the chat conversation surface. It serves the prod client — the embedded
//! chat/*.js bundles — over the on-disk chat tree (chat_store.chat_root). The
//! client boots, paints the transcript from the SSE backlog, sends messages, and
//! receives them live.
//!
//! Routes:
//!   GET  /chat                         index: the conversations this user can see
//!   GET  /chat/<file>.js               an embedded client bundle (colors.js, …)
//!   GET  /chat/c/<conv>                303 → its default topic
//!   GET  /chat/c/<conv>/<sid>          the conversation page (boots the prod JS)
//!   GET  /chat/c/<conv>/<sid>/stream   SSE: backlog replay + LIVE fan-out
//!   POST /chat/c/<conv>/<sid>/send     post a message (fans out to live streams)
//!   GET  /chat/c/<conv>/<sid>/raw      the literal on-disk .md bytes
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
//! Access: identity-or-/login; DM participant gate; channel membership gate;
//! opaque 404 (no existence leak); sid path-traversal guard.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");
const html = @import("html.zig");
const htmlEscape = html.htmlEscape; // internal alias; the impl lives in html.zig
const chrome = @import("chrome.zig");
const page = @import("chat_page.zig");
const sse = @import("chat_sse.zig");
const asset_v = chrome.asset_v; // internal alias; the canonical const lives in chrome.zig
const edge = @import("edge.zig");
const docs = @import("docs.zig");
const reading_list = @import("reading_list.zig");
const recent = @import("recent.zig");
const images = @import("images.zig");
const code = @import("code.zig");
const links = @import("links.zig");
const upload = @import("chat_upload.zig");
const presence = @import("presence.zig");
const chat_state = @import("chat_state.zig");
const download = @import("chat_download.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// Max bytes for one posted message.
const max_message_bytes = 64 * 1024;

// Resolved-conversation domain types (Conv, Topic) live in conv.zig — shared
// with the page renderer (chat_page.zig) so neither side re-discriminates kind.
const Conv = @import("conv.zig").Conv;
const Topic = @import("conv.zig").Topic;

const Asset = struct { name: []const u8, body: []const u8 };

/// The embedded prod client bundles (wired in build.zig). Served verbatim at
/// /chat/<name> with a JS content type.
const assets = [_]Asset{
    .{ .name = "colors.js", .body = @embedFile("chat_js_colors") },
    .{ .name = "viewport.js", .body = @embedFile("chat_js_viewport") },
    .{ .name = "chat_theme.js", .body = @embedFile("chat_js_theme") },
    .{ .name = "chrome_drawer.js", .body = @embedFile("chat_js_chrome_drawer") },
    .{ .name = "chat_image_popup.js", .body = @embedFile("chat_js_image_popup") },
    .{ .name = "chat_code_popup.js", .body = @embedFile("chat_js_code_popup") },
    .{ .name = "chat_time_popup.js", .body = @embedFile("chat_js_time_popup") },
    .{ .name = "chat_save_popup.js", .body = @embedFile("chat_js_save_popup") },
    .{ .name = "message.js", .body = @embedFile("chat_js_message") },
    .{ .name = "message_view.js", .body = @embedFile("chat_js_message_view") },
    .{ .name = "nav_stack.js", .body = @embedFile("chat_js_nav_stack") },
    .{ .name = "middle_pane.js", .body = @embedFile("chat_js_middle_pane") },
    .{ .name = "chat_search.js", .body = @embedFile("chat_js_search") },
    .{ .name = "chat_drag_to_pin.js", .body = @embedFile("chat_js_drag_to_pin") },
    .{ .name = "chat_add_topic.js", .body = @embedFile("chat_js_add_topic") },
    .{ .name = "chat_first_topic.js", .body = @embedFile("chat_js_first_topic") },
    .{ .name = "chat_left_sidebar.js", .body = @embedFile("chat_js_left_sidebar") },
    .{ .name = "chat_right_sidebar.js", .body = @embedFile("chat_js_right_sidebar") },
    .{ .name = "chat_compose.js", .body = @embedFile("chat_js_compose") },
    .{ .name = "chat_help.js", .body = @embedFile("chat_js_help") },
    .{ .name = "chat_responsive.js", .body = @embedFile("chat_js_responsive") },
    .{ .name = "chat.js", .body = @embedFile("chat_js_chat") },
    .{ .name = "notify.js", .body = @embedFile("chat_js_notify") },
    .{ .name = "docs.js", .body = @embedFile("chat_js_docs") },
    .{ .name = "recent.js", .body = @embedFile("chat_js_recent") },
    .{ .name = "styles.js", .body = @embedFile("chat_js_styles") },
    .{ .name = "images.js", .body = @embedFile("chat_js_images") },
    .{ .name = "code.js", .body = @embedFile("chat_js_code") },
};

// ── dispatch ───────────────────────────────────────────────────────────────

/// handle dispatches /chat/* — `sub` keeps its leading '/' (empty for "/chat").
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    // Embedded JS assets are public (the prod server serves them unauthenticated
    // too — they're static client code); resolve them before the identity gate.
    if (sub.len > 1 and std.mem.endsWith(u8, sub, ".js")) {
        return serveAsset(req, sub[1..]);
    }

    const uid = try users.currentUserID(io, alloc, req);
    // NEED_PASSWORD: the whole chat subsystem (DMs, docs, recent, images, code,
    // the conversations API) is members + agents only. A guest (name-only, no
    // password) or a stranger is sent to set a password and returned here —
    // guests may play the game, but chat requires membership.
    if (!users.principalAuthorized(io, alloc, uid)) {
        return http.redirect(req, try std.fmt.allocPrint(alloc, "/login/full?next=/chat{s}", .{sub}));
    }

    // Presence: any authorized page/action counts as activity — but NOT the SSE
    // streams (a stream is the browser's job, and JS assets resolved above). On
    // the offline→online edge this fans a came-online event to other users.
    if (!isStreamPath(sub)) presence.markActiveAndBroadcast(io, alloc, bus, uid);

    // Bare /chat is no longer a conversations INDEX — it resumes you straight
    // into your last conversation (chatDefault), or shows the empty-state page if
    // you have none. Every "Chat" link across the site points here, so the resume
    // behaviour is centralized in one handler.
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        return chatDefault(req, io, alloc, uid);
    }
    // /chat/docs[/...] — the three-pane authoring surface (docs.zig). Guard the
    // boundary so only "/docs" or "/docs/..." matches (".js" is already served
    // above; anything like "/docsX" falls through to 404).
    if (matchPrefix(sub, "/docs")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try docs.handle(req, io, alloc, bus, uid, rest);
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
    // /chat/links — a per-user curated links page (links.zig). Static: no stream.
    if (matchPrefix(sub, "/links")) |rest| {
        if (rest.len == 0 or rest[0] == '/') {
            try links.handle(req, io, alloc, uid, rest);
            return;
        }
    }
    // /chat/default — resume the last (conv, session); /chat/conversations —
    // the (partner × session) matrix as JSON (the API-key discovery entry point);
    // /chat/msg/<id> — resolve a global MSG_ ref to its thread and 302 there.
    if (std.mem.eql(u8, sub, "/default")) return chatDefault(req, io, alloc, uid);
    if (std.mem.eql(u8, sub, "/conversations")) return chatConversations(req, io, alloc, uid);
    if (matchPrefix(sub, "/msg/")) |id| return chatMsgLookup(req, io, alloc, uid, id);
    if (matchPrefix(sub, "/c/")) |rest| {
        try convRoute(req, io, alloc, bus, uid, rest);
        return;
    }
    // The two cross-page attention streams the prod JS opens on boot. Both are
    // per-uid bus subscribers forwarding the published event JSON verbatim
    // (notify: status-strip pings + came-online; sidebar: topic-added +
    // user-online). Live-only — the server-rendered page is the backlog.
    if (std.mem.eql(u8, sub, "/notifications")) {
        return sse.forwardUserStream(req, alloc, bus, try store.notifyBusKey(alloc, uid));
    }
    if (std.mem.eql(u8, sub, "/sidebar/stream")) {
        return sse.forwardUserStream(req, alloc, bus, try store.sidebarBusKey(alloc, uid));
    }
    try http.notFound(req);
}

/// handleChannel dispatches /channel/* — `sub` is the path after "/channel".
pub fn handleChannel(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    const uid = try users.currentUserID(io, alloc, req);
    // NEED_PASSWORD: channels are members + agents only (same gate as /chat).
    if (!users.principalAuthorized(io, alloc, uid)) {
        return http.redirect(req, try std.fmt.allocPrint(alloc, "/login/full?next=/channel{s}", .{sub}));
    }
    if (!isStreamPath(sub)) presence.markActiveAndBroadcast(io, alloc, bus, uid);

    var segs = segments(sub);
    const name_raw = segs.next() orelse return http.notFound(req);
    if (!store.validChannelName(name_raw)) return http.notFound(req);
    // No dupe: the router resolved the path via http.target, which owns it, so
    // path-derived slices already survive the body read.
    const name = name_raw;

    const members = (try store.channelMembers(io, alloc, name)) orelse return http.notFound(req);
    if (!store.hasMember(members, uid)) return http.notFound(req);

    const conv = Conv{
        .meta = .{ .kind = .channel, .members = members },
        .key = name,
        .base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name}),
        .dir = try store.channelConvDir(alloc, name),
    };

    const topic_raw = segs.next() orelse {
        const def = try store.defaultSession(io, alloc, conv.dir);
        if (def.len == 0) {
            // Member of a channel with no topics yet — offer to start the first.
            const title = try std.fmt.allocPrint(alloc, "#{s}", .{name});
            return page.firstTopicPage(req, io, alloc, uid, conv.base, title);
        }
        return http.redirect(req, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv.base, def }));
    };
    // /channel/<name>/new — create a topic ("new" is reserved).
    if (std.mem.eql(u8, topic_raw, "new")) return newTopic(req, io, alloc, bus, conv, uid);
    if (!store.validSessionID(topic_raw)) return http.notFound(req);
    const topic = topic_raw; // owned via the router's http.target (see `name` above)

    const title = try std.fmt.allocPrint(alloc, "#{s}: {s}", .{ name, topic });
    try topicRoute(req, io, alloc, bus, &segs, uid, Topic{ .conv = conv, .sid = topic, .title = title });
}

/// convRoute handles /chat/c/<conv>[/<sid>[/raw|stream|send]]. `rest` is after "/c/".
fn convRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    var segs = segments(rest);
    const pair_raw = segs.next() orelse return http.notFound(req);
    if (!try store.chatKeyParticipant(alloc, pair_raw, uid)) return http.notFound(req);
    // No dupe: the router resolved the path via http.target, which owns it, so
    // these path-derived strings (used after the body read for response URLs,
    // fanout keys, member uids) already survive head invalidation.
    const pair = pair_raw;

    // DM members are the two uids in the (already participant-checked) pair key.
    const us = std.mem.indexOfScalar(u8, pair, '_').?;
    const members = try alloc.alloc([]const u8, 2);
    members[0] = pair[0..us];
    members[1] = pair[us + 1 ..];
    const conv = Conv{
        .meta = .{ .kind = .dm, .members = members },
        .key = pair,
        .base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{pair}),
        .dir = try store.dmConvDir(alloc, pair),
    };

    const sid_raw = segs.next() orelse {
        const def = try store.defaultSession(io, alloc, conv.dir);
        if (def.len == 0) {
            // Addressable pair, no topics yet — offer to start the first one
            // (rather than 404 a real, reachable conversation).
            const partner = try partnerName(io, alloc, conv.key, uid);
            const title = try std.fmt.allocPrint(alloc, "Chat w/{s}", .{partner});
            return page.firstTopicPage(req, io, alloc, uid, conv.base, title);
        }
        return http.redirect(req, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv.base, def }));
    };
    // /chat/c/<conv>/new — create a topic ("new" beats {sid}; it's reserved).
    if (std.mem.eql(u8, sid_raw, "new")) return newTopic(req, io, alloc, bus, conv, uid);
    if (!store.validSessionID(sid_raw)) return http.notFound(req);
    const sid = sid_raw; // owned via the router's http.target (see `pair` above)

    const partner = try partnerName(io, alloc, conv.key, uid);
    const title = try std.fmt.allocPrint(alloc, "Chat w/{s}: {s}", .{ partner, sid });
    try topicRoute(req, io, alloc, bus, &segs, uid, Topic{ .conv = conv, .sid = sid, .title = title });
}

/// topicRoute fans out the per-topic tail shared by DMs and channels: the bare
/// page, `/stream` (SSE), `/send` (POST a message), or `/raw` (literal bytes).
/// `segs` is positioned just after the sid. `title` is the top-bar title.
fn topicRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, segs: *SegIter, uid: []const u8, topic: Topic) !void {
    const conv = topic.conv;
    const tail = segs.next() orelse {
        try page.conversationPage(req, io, alloc, uid, topic);
        return;
    };
    // /uploads/<file> — serve a stored image (two trailing segments).
    if (std.mem.eql(u8, tail, "uploads")) {
        const file = segs.next() orelse return http.notFound(req);
        if (segs.next() != null) return http.notFound(req);
        return upload.serveUpload(req, io, alloc, conv.dir, topic.sid, file);
    }
    if (segs.next() != null) return http.notFound(req); // the rest take no further segment
    if (std.mem.eql(u8, tail, "stream")) {
        try sse.streamTranscript(req, io, alloc, bus, conv.dir, conv.key, topic.sid, uid);
    } else if (std.mem.eql(u8, tail, "send")) {
        try sendMessage(req, io, alloc, bus, topic, uid);
    } else if (std.mem.eql(u8, tail, "upload")) {
        try upload.handleUpload(req, io, alloc, uid, conv.dir, conv.base, topic.sid);
    } else if (std.mem.eql(u8, tail, "pin")) {
        try pinSession(req, io, alloc, uid, conv.key, topic.sid, true);
    } else if (std.mem.eql(u8, tail, "unpin")) {
        try pinSession(req, io, alloc, uid, conv.key, topic.sid, false);
    } else if (std.mem.eql(u8, tail, "raw")) {
        try rawTranscript(req, io, alloc, conv.dir, topic.sid);
    } else if (std.mem.eql(u8, tail, "download")) {
        try download.serveBundle(req, io, alloc, conv.dir, topic.sid);
    } else if (std.mem.eql(u8, tail, "saved")) {
        try savedIds(req, io, alloc, uid, conv.key, topic.sid);
    } else {
        try http.notFound(req);
    }
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
/// a plain form post → 303 back to the topic. Empty / DROP_ON_FLOOR bodies report
/// success without appending (the client's no-echo path).
fn sendMessage(req: *Request, io: Io, alloc: Alloc, bus: *Bus, topic: Topic, uid: []const u8) !void {
    const conv = topic.conv;
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    // Read headers BEFORE the body: reading the request body advances the
    // std.http.Server reader past `received_head`, after which iterateHeaders
    // asserts. So capture X-Chat-Async first, then drain the body.
    const is_async = if (try http.header(req, alloc, "x-chat-async")) |v| std.mem.eql(u8, v, "1") else false;

    const body = (try http.readLimitedBody(req, alloc, max_message_bytes)) orelse return;
    const md_raw = (try formField(alloc, body, "markdown")) orelse "";
    const cid = (try formField(alloc, body, "cid")) orelse "";
    const md = std.mem.trim(u8, md_raw, " \t\r\n");

    if (md.len == 0 or std.mem.startsWith(u8, md, "DROP_ON_FLOOR")) {
        return sendDone(req, alloc, is_async, conv.base, topic.sid);
    }

    // Refuse hostile / absurdly over-formatted markdown at the door rather than
    // store it: fail loud to the author (a 400) instead of fanning out content
    // that every reader would render as the malformed placeholder anyway.
    if (markdown.hostileReason(alloc, md)) |_| {
        return edge.reject(req, .malformed_markdown, "not sent: malformed markdown — too much formatting; break it into smaller messages\n");
    }

    const from_name = try users.getUserName(io, alloc, uid);
    _ = try store.appendMessage(io, alloc, bus, conv.meta, conv.dir, conv.key, topic.sid, from_name, uid, md, cid);
    users.touchUser(io, alloc, uid);
    if (conv.persistsCursor()) chat_state.setUserLastSession(io, alloc, uid, conv.key, topic.sid);
    return sendDone(req, alloc, is_async, conv.base, topic.sid);
}

/// pinSession handles POST /<…>/<sid>/{pin,unpin}: toggle
/// whether `sid` is in the caller's per-conv Pinned group, then 204. Per-user
/// state; conv-level auth already passed (any participant pins their own view).
fn pinSession(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8, pinned: bool) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);
    chat_state.setSessionPinned(io, alloc, uid, conv_key, sid, pinned);
    return req.respond("", .{ .status = .no_content });
}

/// sendDone reports a (possibly no-op) send: 204 for async fetch callers, else a
/// 303 back to the topic page (the no-JS form-post fallback).
fn sendDone(req: *Request, alloc: Alloc, is_async: bool, base: []const u8, sid: []const u8) !void {
    if (is_async) return req.respond("", .{ .status = .no_content });
    const loc = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid });
    return http.redirect(req, loc);
}

// ── new topic ─────────────────────────────────────────────────────────────────

/// newTopic handles POST <conv-base>/new:
/// validate the `topic` form field, refuse duplicates + the reserved "new", then
/// seed the session with a first "hi" message (which fans out topic-added). For a
/// DM it also remembers the new topic as last-viewed and announces it as a link
/// in the highest generalN session, where the partner already watches. Returns
/// `{conv, sid}` JSON. Shared by DMs and channels (kind gates the DM-only extras).
fn newTopic(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv: Conv, uid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    const body = (try http.readLimitedBody(req, alloc, max_message_bytes)) orelse return;
    const topic_raw = (try formField(alloc, body, "topic")) orelse "";
    const topic = std.mem.trim(u8, topic_raw, " \t\r\n");
    if (!store.validSessionID(topic)) {
        return req.respond("Topic must be letters, digits, and hyphens only — no spaces, underscores, or punctuation.\n", .{ .status = .bad_request });
    }
    if (std.mem.eql(u8, topic, "new")) {
        return req.respond("\"new\" is reserved — pick another topic name.\n", .{ .status = .bad_request });
    }
    for (try store.listSessions(io, alloc, conv.dir)) |s| {
        if (std.mem.eql(u8, s, topic)) return req.respond("That topic already exists.\n", .{ .status = .conflict });
    }

    const from_name = try users.getUserName(io, alloc, uid);
    _ = try store.appendMessage(io, alloc, bus, conv.meta, conv.dir, conv.key, topic, from_name, uid, "hi", "");
    users.touchUser(io, alloc, uid);

    if (conv.persistsCursor()) {
        chat_state.setUserLastSession(io, alloc, uid, conv.key, topic);
        // Announce the new topic where the partner already watches (best-effort).
        if (try highestGeneralSession(io, alloc, conv.dir)) |gen| {
            if (!std.mem.eql(u8, gen, topic)) {
                const note = try std.fmt.allocPrint(alloc, "New topic: [{s}]({s}/{s})", .{ topic, conv.base, topic });
                _ = store.appendMessage(io, alloc, bus, conv.meta, conv.dir, conv.key, gen, from_name, uid, note, "") catch {};
            }
        }
    }

    const out = try std.fmt.allocPrint(alloc, "{{\"conv\":{f},\"sid\":{f}}}", .{ std.json.fmt(conv.key, .{}), std.json.fmt(topic, .{}) });
    try req.respond(out, .{ .extra_headers = &.{http.json_ct} });
}

/// highestGeneralSession returns the "general<N>" session with the largest N in
/// `dir`, or null when there is none.
fn highestGeneralSession(io: Io, alloc: Alloc, dir: []const u8) !?[]const u8 {
    var best: ?[]const u8 = null;
    var best_n: i64 = -1;
    for (try store.listSessions(io, alloc, dir)) |s| {
        if (!std.mem.startsWith(u8, s, "general")) continue;
        const n = std.fmt.parseInt(i64, s["general".len..], 10) catch continue;
        if (n > best_n) {
            best_n = n;
            best = s;
        }
    }
    return best;
}

// ── default / conversations / msg-ref lookup ──────────────────────────────────

/// chatDefault resumes the viewer's last conversation: read their last-conv
/// bookmark, resolve its landing session, and 302 into /chat/c/<conv>/<sid>. It
/// backs both bare /chat and /chat/default. When there's no bookmark (or it names
/// a conv they no longer participate in), we render the "no conversations" page
/// rather than redirect — the invariant that everyone has SOME conversation isn't
/// enforced yet, so this is the honest empty state.
fn chatDefault(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const conv = try chat_state.lastUserConv(io, alloc, uid);
    if (conv.len == 0 or !(try store.chatKeyParticipant(alloc, conv, uid))) {
        return page.noConversationsPage(req, io, alloc, uid);
    }
    const sid = try chat_state.resolveSessionForUser(io, alloc, uid, conv);
    return http.redirect(req, try std.fmt.allocPrint(alloc, "/chat/c/{s}/{s}", .{ conv, sid }));
}

/// chatConversations serves GET /chat/conversations: the (partner × session)
/// matrix as JSON — every other authorized principal, each conv's default
/// landing session and its session list (sorted). The discovery entry point for
/// API-key clients.
fn chatConversations(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req);

    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "{{\"me\":{f},\"conversations\":[", .{std.json.fmt(uid, .{})});
    var first = true;
    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        const conv = try store.chatPairKey(alloc, uid, partner.id);
        const def = try chat_state.resolveSessionForUser(io, alloc, uid, conv);
        const dir = try store.dmConvDir(alloc, conv);
        try b.print(alloc, "{{\"conv\":{f},\"partner\":{{\"id\":{f},\"name\":{f}}},\"default\":{f},\"sessions\":[", .{
            std.json.fmt(conv, .{}), std.json.fmt(partner.id, .{}), std.json.fmt(partner.name, .{}), std.json.fmt(def, .{}),
        });
        var sfirst = true;
        for (try store.listSessions(io, alloc, dir)) |s| {
            if (!sfirst) try b.append(alloc, ',');
            sfirst = false;
            try b.print(alloc, "{f}", .{std.json.fmt(s, .{})});
        }
        try b.appendSlice(alloc, "]}");
    }
    try b.appendSlice(alloc, "]}");
    try req.respond(b.items, .{ .extra_headers = &.{http.json_ct} });
}

/// chatMsgLookup resolves a global MSG_<id> to the thread it lives in and 302s to
/// that topic URL + #msg-<id>. Walks the viewer's accessible convs (DM partners,
/// then channels) and picks the first whose session list holds the sid embedded
/// in the id.
fn chatMsgLookup(req: *Request, io: Io, alloc: Alloc, uid: []const u8, id: []const u8) !void {
    if (!store.validMsgRefID(id)) return http.notFound(req);
    const cut = std.mem.lastIndexOfScalar(u8, id, '_').?; // validMsgRefID guarantees one
    const sid = id[0..cut];

    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        const conv = try store.chatPairKey(alloc, uid, partner.id);
        const dir = try store.dmConvDir(alloc, conv);
        if (try convHasSession(io, alloc, dir, sid)) {
            return redirectFound(req, try std.fmt.allocPrint(alloc, "/chat/c/{s}/{s}#msg-{s}", .{ conv, sid, id }));
        }
    }
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        const dir = try store.channelConvDir(alloc, name);
        if (try convHasSession(io, alloc, dir, sid)) {
            return redirectFound(req, try std.fmt.allocPrint(alloc, "/channel/{s}/{s}#msg-{s}", .{ name, sid, id }));
        }
    }
    return http.notFound(req);
}

/// convHasSession reports whether `dir`'s session list contains `sid`.
fn convHasSession(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) !bool {
    for (try store.listSessions(io, alloc, dir)) |s| {
        if (std.mem.eql(u8, s, sid)) return true;
    }
    return false;
}

/// redirectFound issues a 302 to `location` — the msg-ref
/// lookup uses 302 (a transient lookup-then-go), not the 303 the others use.
fn redirectFound(req: *Request, location: []const u8) !void {
    return req.respond("", .{
        .status = .found,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

// ── raw + index ──────────────────────────────────────────────────────────────

/// rawTranscript serves the literal on-disk .md bytes (text/plain, nosniff).
fn rawTranscript(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    const data = (try store.rawSession(io, alloc, conv_dir, sid)) orelse return http.notFound(req);
    try req.respond(data, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

/// serveAsset serves an embedded client bundle by file name (no leading slash).
fn serveAsset(req: *Request, name: []const u8) !void {
    for (assets) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            return req.respond(a.body, .{ .extra_headers = &.{http.js_ct} });
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
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return try urlDecode(alloc, pair[eq + 1 ..]);
    }
    return null;
}

/// urlDecode reverses form-urlencoding: '+' → space, '%XX' → byte, else verbatim.
fn urlDecode(alloc: Alloc, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try out.append(alloc, ' ');
        } else if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(alloc, hi.? * 16 + lo.?);
                i += 2;
            } else try out.append(alloc, c);
        } else try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
