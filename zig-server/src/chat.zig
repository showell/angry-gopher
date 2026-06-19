//! chat: the chat conversation surface of the zig port. It serves the SAME prod
//! client the Go server serves — the embedded chat/*.js bundles, byte-for-byte —
//! on the SAME on-disk chat tree Go writes (chat_store.chat_root). The real
//! client boots on the zig server, paints the transcript from the SSE backlog,
//! sends messages, and receives them live.
//!
//! Routes (mirror Go's URL space, server/chat/chat.go):
//!   GET  /chat                         index: the conversations this user can see
//!   GET  /chat/<file>.js               an embedded client bundle (colors.js, …)
//!   GET  /chat/c/<conv>                303 → its default topic
//!   GET  /chat/c/<conv>/<sid>          the conversation page (boots the prod JS)
//!   GET  /chat/c/<conv>/<sid>/stream   SSE: backlog replay + LIVE fan-out
//!   POST /chat/c/<conv>/<sid>/send     post a message (fans out to live streams)
//!   GET  /chat/c/<conv>/<sid>/raw      the literal on-disk .md bytes
//!   {GET,POST} /channel/<name>/<topic>{,/stream,/send,/raw}   the channel equivalents
//!   GET  /chat/notifications | /chat/sidebar/stream   keepalive-only stubs (the
//!                                      prod JS opens these on boot; no events yet)
//!
//! Live delivery within this binary: a /send append publishes a fan-out blob to
//! bus.zig (the spike's bus, now graduated), and every open /stream on the same
//! conv/sid drains it — so a message sent from the zig page appears live in
//! every zig tab. The ONE gap (Steve's call): a message posted via the GO server
//! lands on disk but NOT on this server's bus, so it shows on RELOAD, not live —
//! cross-process append can't notify a different process's bus. (Notifications /
//! sidebar presence are still keepalive-only stubs.)
//!
//! Access mirrors Go: identity-or-/login; DM participant gate; channel
//! membership gate; opaque 404 (no existence leak); sid path-traversal guard.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// Max bytes for one posted message (Go's maxChatMessageBytes).
const max_message_bytes = 64 * 1024;

/// Asset version (cache-buster). The Go server uses the git sha / "dev"; the zig
/// port has no build stamp, so a constant suffices — it only namespaces the
/// browser cache, and :9001 is a separate origin from Go's :9000 anyway.
const asset_v = "zig";

const Kind = enum { dm, channel };

const Asset = struct { name: []const u8, body: []const u8 };

/// The embedded prod client bundles (wired in build.zig). Served verbatim at
/// /chat/<name> with a JS content type — the IDENTICAL bytes Go serves.
const assets = [_]Asset{
    .{ .name = "colors.js", .body = @embedFile("chat_js_colors") },
    .{ .name = "chat_theme.js", .body = @embedFile("chat_js_theme") },
    .{ .name = "chat_image_popup.js", .body = @embedFile("chat_js_image_popup") },
    .{ .name = "chat_code_popup.js", .body = @embedFile("chat_js_code_popup") },
    .{ .name = "chat_time_popup.js", .body = @embedFile("chat_js_time_popup") },
    .{ .name = "message.js", .body = @embedFile("chat_js_message") },
    .{ .name = "message_view.js", .body = @embedFile("chat_js_message_view") },
    .{ .name = "nav_stack.js", .body = @embedFile("chat_js_nav_stack") },
    .{ .name = "middle_pane.js", .body = @embedFile("chat_js_middle_pane") },
    .{ .name = "chat_search.js", .body = @embedFile("chat_js_search") },
    .{ .name = "chat_drag_to_pin.js", .body = @embedFile("chat_js_drag_to_pin") },
    .{ .name = "chat_add_topic.js", .body = @embedFile("chat_js_add_topic") },
    .{ .name = "chat_left_sidebar.js", .body = @embedFile("chat_js_left_sidebar") },
    .{ .name = "chat_right_sidebar.js", .body = @embedFile("chat_js_right_sidebar") },
    .{ .name = "chat_compose.js", .body = @embedFile("chat_js_compose") },
    .{ .name = "chat_help.js", .body = @embedFile("chat_js_help") },
    .{ .name = "chat.js", .body = @embedFile("chat_js_chat") },
    .{ .name = "notify.js", .body = @embedFile("chat_js_notify") },
};

/// The sibling bundles the conversation page loads, in document order (after the
/// head's colors.js + chat_theme.js). Mirrors renderConversation's script list.
const page_scripts = [_][]const u8{
    "chat_image_popup.js", "chat_code_popup.js",   "chat_time_popup.js",
    "message.js",          "message_view.js",      "nav_stack.js",
    "middle_pane.js",      "chat_search.js",       "chat_drag_to_pin.js",
    "chat_add_topic.js",   "chat_left_sidebar.js", "chat_right_sidebar.js",
    "chat_compose.js",     "chat_help.js",         "chat.js",
    "notify.js",
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
    if (uid.len == 0) return http.redirect(req, "/login");

    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try indexPage(req, io, alloc, uid);
        return;
    }
    if (matchPrefix(sub, "/c/")) |rest| {
        try convRoute(req, io, alloc, bus, uid, rest);
        return;
    }
    // Secondary boot streams the prod JS opens (notify.js, the left sidebar):
    // stubbed as keepalive-only so the client connects cleanly without a
    // 404-reconnect loop. They carry no events yet (presence / cross-conv
    // notifications land with the write path), and the JS reacts only to real
    // onmessage events, so an idle stream is the correct "nothing happening".
    if (std.mem.eql(u8, sub, "/notifications") or std.mem.eql(u8, sub, "/sidebar/stream")) {
        try keepaliveStream(req, io);
        return;
    }
    try http.notFound(req);
}

/// handleChannel dispatches /channel/* — `sub` is the path after "/channel".
pub fn handleChannel(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0) return http.redirect(req, "/login");

    var segs = segments(sub);
    const name = segs.next() orelse return http.notFound(req);
    if (!store.validChannelName(name)) return http.notFound(req);

    const members = (try store.channelMembers(io, alloc, name)) orelse return http.notFound(req);
    if (!store.hasMember(members, uid)) return http.notFound(req);

    const dir = try store.channelConvDir(alloc, name);
    const base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});

    const topic = segs.next() orelse {
        const def = try store.defaultSession(io, alloc, dir);
        if (def.len == 0) return http.notFound(req);
        return http.redirect(req, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, def }));
    };
    if (!store.validSessionID(topic)) return http.notFound(req);

    const title = try std.fmt.allocPrint(alloc, "#{s}: {s}", .{ name, topic });
    try topicRoute(req, io, alloc, bus, &segs, uid, .channel, name, base, dir, topic, title);
}

/// convRoute handles /chat/c/<conv>[/<sid>[/raw|stream|send]]. `rest` is after "/c/".
fn convRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    var segs = segments(rest);
    const conv = segs.next() orelse return http.notFound(req);
    if (!try store.chatKeyParticipant(alloc, conv, uid)) return http.notFound(req);

    const dir = try store.dmConvDir(alloc, conv);
    const base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv});

    const sid = segs.next() orelse {
        const def = try store.defaultSession(io, alloc, dir);
        if (def.len == 0) return http.notFound(req);
        return http.redirect(req, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, def }));
    };
    if (!store.validSessionID(sid)) return http.notFound(req);

    const partner = try partnerName(io, alloc, conv, uid);
    const title = try std.fmt.allocPrint(alloc, "Chat w/{s}: {s}", .{ partner, sid });
    try topicRoute(req, io, alloc, bus, &segs, uid, .dm, conv, base, dir, sid, title);
}

/// topicRoute fans out the per-topic tail shared by DMs and channels: the bare
/// page, `/stream` (SSE), `/send` (POST a message), or `/raw` (literal bytes).
/// `segs` is positioned just after the sid. `title` is the top-bar title.
fn topicRoute(req: *Request, io: Io, alloc: Alloc, bus: *Bus, segs: *SegIter, uid: []const u8, kind: Kind, conv_key: []const u8, base: []const u8, dir: []const u8, sid: []const u8, title: []const u8) !void {
    const tail = segs.next();
    if (tail == null) {
        try conversationPage(req, io, alloc, uid, kind, conv_key, base, dir, sid, title);
        return;
    }
    if (segs.next() != null) return http.notFound(req); // at most one trailing segment
    const t = tail.?;
    if (std.mem.eql(u8, t, "stream")) {
        try streamTranscript(req, io, alloc, bus, dir, conv_key, sid, uid);
    } else if (std.mem.eql(u8, t, "send")) {
        try sendMessage(req, io, alloc, bus, dir, conv_key, base, sid, uid);
    } else if (std.mem.eql(u8, t, "raw")) {
        try rawTranscript(req, io, alloc, dir, sid);
    } else {
        try http.notFound(req);
    }
}

// ── the conversation page (boots the prod JS) ────────────────────────────────

fn conversationPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, kind: Kind, conv_key: []const u8, base: []const u8, dir: []const u8, sid: []const u8, title: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const sidebar_json = try buildSidebarJSON(io, alloc, uid, kind, conv_key, base, dir, sid);

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, page_head); // doctype + <head> + platform style + <body>

    // chat-subsystem chrome: colors.js (sync, sets the palette pre-paint) +
    // chat_theme.js (deferred) + the top bar + open .app-body-wrap.
    try b.print(alloc, head_scripts, .{ asset_v, asset_v });
    try b.print(alloc, chrome_top, .{ try htmlEscape(alloc, title), try htmlEscape(alloc, viewer) });
    try b.appendSlice(alloc, "<div class=\"app-body-wrap\">");

    try b.appendSlice(alloc, chat_css);
    try b.print(alloc, "<div id=\"chat-root\" data-conv=\"{s}\" data-conv-base=\"{s}\" data-session=\"{s}\">", .{
        try htmlEscape(alloc, conv_key), try htmlEscape(alloc, base), try htmlEscape(alloc, sid),
    });
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div class=\"chat-layout\">");

    // left-rail mount + the inline sidebar payload (first paint, no round-trip).
    try b.appendSlice(alloc, "<div id=\"chat-left-sidebar\"></div>");
    try b.print(alloc, "<script type=\"application/json\" id=\"chat-sidebar-data\">{s}</script>", .{sidebar_json});

    try b.appendSlice(alloc, "<div id=\"chat-feed\"></div>");
    try b.appendSlice(alloc, "<div id=\"chat-right-sidebar\"></div></div>");

    // sibling bundles, in document order, then close #chat-root + the body.
    try b.appendSlice(alloc, "</div>");
    for (page_scripts) |name| {
        try b.print(alloc, "<script src=\"/chat/{s}?v={s}\"></script>", .{ name, asset_v });
    }
    try b.appendSlice(alloc, "</div></body></html>");

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// buildSidebarJSON is the inline left-rail payload (Go's buildSidebarPayload):
/// conversations = every other authorized user (DM) + every channel the viewer
/// is in; pinned_sessions = [] (pins not ported yet); sessions = this conv's
/// topics. The `</`→`<\/` pass mirrors Go's script-tag-safety replacement.
fn buildSidebarJSON(io: Io, alloc: Alloc, uid: []const u8, kind: Kind, conv_key: []const u8, base: []const u8, dir: []const u8, sid: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, "{\"conversations\":[");

    var first = true;
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, uid)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        const pk = try store.chatPairKey(alloc, uid, u.id);
        const active = kind == .dm and std.mem.eql(u8, pk, conv_key);
        try b.print(alloc, "{{\"id\":\"uid:{s}\",\"label\":{f},\"url\":\"/chat/c/{s}\",\"active\":{}}}", .{
            u.id, std.json.fmt(u.name, .{}), pk, active,
        });
    }
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        if (!first) try b.append(alloc, ',');
        first = false;
        const active = kind == .channel and std.mem.eql(u8, name, conv_key);
        const label = try std.fmt.allocPrint(alloc, "# {s}", .{name});
        try b.print(alloc, "{{\"id\":\"ch:{s}\",\"label\":{f},\"url\":\"/channel/{s}\",\"active\":{}}}", .{
            name, std.json.fmt(label, .{}), name, active,
        });
    }

    try b.appendSlice(alloc, "],\"pinned_sessions\":[],\"sessions\":[");
    first = true;
    for (try store.listSessions(io, alloc, dir)) |s| {
        if (!first) try b.append(alloc, ',');
        first = false;
        const active = std.mem.eql(u8, s, sid);
        const u = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, s });
        try b.print(alloc, "{{\"id\":{f},\"label\":{f},\"url\":{f},\"active\":{}}}", .{
            std.json.fmt(s, .{}), std.json.fmt(s, .{}), std.json.fmt(u, .{}), active,
        });
    }
    try b.appendSlice(alloc, "]}");

    return replaceSeq(alloc, b.items, "</", "<\\/");
}

// ── SSE stream (backlog replay + keepalive) ──────────────────────────────────

/// streamTranscript serves /<…>/<sid>/stream — Go's serveChatStream: the
/// `backlog-size` preamble, the backlog replay from the cursor, then LIVE
/// messages off the bus (a message posted to this conv/sid via /send fans out
/// here), with `: ping` keepalives when idle. openStream decodes the backlog and
/// subscribes atomically, so each message lands in EITHER the backlog OR the
/// live stream — never both, never neither.
fn streamTranscript(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8) !void {
    const since = parseSince(req);
    const viewer = try users.getUserName(io, alloc, uid);

    const stream = try store.openStream(io, alloc, bus, conv_dir, conv_key, sid);
    defer bus.close(stream.sub);

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &http.sse_headers },
    }) catch return;

    const backlog_size = if (stream.backlog.len > since) stream.backlog.len - since else 0;
    {
        const pre = try std.fmt.allocPrint(alloc, "event: backlog-size\ndata: {d}\n\n", .{backlog_size});
        http.pushFrame(&body, pre) catch return;
    }

    var i: usize = since;
    while (i < stream.backlog.len) : (i += 1) {
        const m = stream.backlog[i];
        const frame = try emitWire(alloc, i, m.from, m.date, m.markdown, m.id, std.mem.eql(u8, m.from, viewer), "");
        http.pushFrame(&body, frame) catch return;
    }

    // Live: drain the subscriber. `.msg` is one fan-out blob (caller frees);
    // `.idle` is the keepalive window — send a ping so a vanished client is
    // noticed (the failed write ends the loop and the defer closes the sub).
    while (true) {
        switch (stream.sub.next()) {
            .msg => |raw| {
                defer stream.sub.alloc.free(raw);
                const frame = liveFrame(alloc, raw, viewer) catch continue;
                http.pushFrame(&body, frame) catch return;
            },
            .idle => http.pushFrame(&body, ": ping\n\n") catch return,
        }
    }
}

/// The fan-out blob shape appendMessage publishes (every wire field except the
/// per-viewer `mine` and the per-stream-rendered `html`).
const BusMsg = struct {
    index: usize,
    from: []const u8,
    at: []const u8,
    id: []const u8,
    cid: []const u8,
    markdown: []const u8,
};

/// liveFrame turns one bus blob into this viewer's SSE event: parse it, render
/// html from the markdown, compute `mine` against the viewer's name, emit.
fn liveFrame(alloc: Alloc, raw: []const u8, viewer: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(BusMsg, alloc, raw, .{});
    defer parsed.deinit();
    const m = parsed.value;
    return emitWire(alloc, m.index, m.from, m.at, m.markdown, m.id, std.mem.eql(u8, m.from, viewer), m.cid);
}

/// emitWire builds one SSE message event (Go's writeChatEvent + chatWireMsg):
/// `id: <index>` then a `data:` line of JSON. `html` is rendered from `markdown`
/// via the markdown port; `mine` is viewer-relative; `cid` is included only when
/// non-empty (Go's omitempty — set on live broadcasts, absent on backlog).
fn emitWire(alloc: Alloc, index: usize, from: []const u8, at: []const u8, md: []const u8, id: []const u8, mine: bool, cid: []const u8) ![]const u8 {
    const html = try markdown.render(alloc, md);
    if (cid.len > 0) {
        return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f},\"mine\":{},\"cid\":{f}}}\n\n", .{
            index,                   index,
            std.json.fmt(from, .{}), std.json.fmt(at, .{}),
            std.json.fmt(html, .{}), std.json.fmt(md, .{}),
            std.json.fmt(id, .{}),   mine,
            std.json.fmt(cid, .{}),
        });
    }
    return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f},\"mine\":{}}}\n\n", .{
        index,                   index,
        std.json.fmt(from, .{}), std.json.fmt(at, .{}),
        std.json.fmt(html, .{}), std.json.fmt(md, .{}),
        std.json.fmt(id, .{}),   mine,
    });
}

// ── send (write path) ────────────────────────────────────────────────────────

/// sendMessage handles POST /<…>/<sid>/send — Go's HandleChatSend/
/// serveSendMessage: parse the markdown+cid form, append (which fans out live to
/// every open stream on this conv/sid), and report. `X-Chat-Async: 1` → 204;
/// a plain form post → 303 back to the topic. Empty / DROP_ON_FLOOR bodies report
/// success without appending (the client's no-echo path).
fn sendMessage(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, base: []const u8, sid: []const u8, uid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    // Read headers BEFORE the body: reading the request body advances the
    // std.http.Server reader past `received_head`, after which iterateHeaders
    // asserts. So capture X-Chat-Async first, then drain the body.
    const is_async = if (header(req, "x-chat-async")) |v| std.mem.eql(u8, v, "1") else false;

    const body = (try http.readLimitedBody(req, alloc, max_message_bytes)) orelse return;
    const md_raw = (try formField(alloc, body, "markdown")) orelse "";
    const cid = (try formField(alloc, body, "cid")) orelse "";
    const md = std.mem.trim(u8, md_raw, " \t\r\n");

    if (md.len == 0 or std.mem.startsWith(u8, md, "DROP_ON_FLOOR")) {
        return sendDone(req, alloc, is_async, base, sid);
    }

    const from_name = try users.getUserName(io, alloc, uid);
    _ = try store.appendMessage(io, alloc, bus, conv_dir, conv_key, sid, from_name, uid, md, cid);
    users.touchUser(io, alloc, uid);
    return sendDone(req, alloc, is_async, base, sid);
}

/// sendDone reports a (possibly no-op) send: 204 for async fetch callers, else a
/// 303 back to the topic page (the no-JS form-post fallback).
fn sendDone(req: *Request, alloc: Alloc, is_async: bool, base: []const u8, sid: []const u8) !void {
    if (is_async) return req.respond("", .{ .status = .no_content });
    const loc = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid });
    return http.redirect(req, loc);
}

/// keepaliveStream opens an SSE response that carries no events — just `: ok`
/// then `: ping` every 25s. Used to satisfy the prod JS's secondary boot
/// streams (notifications, sidebar) without a 404-reconnect loop.
fn keepaliveStream(req: *Request, io: Io) !void {
    var hbuf: [1024]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &http.sse_headers },
    }) catch return;
    http.pushFrame(&body, ": ok\n\n") catch return;
    while (true) {
        io.sleep(.fromSeconds(25), .awake) catch return;
        http.pushFrame(&body, ": ping\n\n") catch return;
    }
}

/// wireFrame builds one SSE message event: `id: <index>` + a `data:` line whose
/// JSON is Go's chatWireMsg. `cid` is omitted (omitempty) — backlog only, no
/// live correlation id. `mine` = the sender's display name equals the viewer's.
fn wireFrame(alloc: Alloc, index: usize, m: store.ChatMessage, viewer: []const u8) ![]const u8 {
    const html_body = try markdown.render(alloc, m.markdown);
    const mine = std.mem.eql(u8, m.from, viewer);
    return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f},\"mine\":{}}}\n\n", .{
        index,                        index,
        std.json.fmt(m.from, .{}),    std.json.fmt(m.date, .{}),
        std.json.fmt(html_body, .{}), std.json.fmt(m.markdown, .{}),
        std.json.fmt(m.id, .{}),      mine,
    });
}

/// parseSince extracts the replay cursor: Last-Event-ID (reconnect) → n+1, else
/// ?since=N (initial load) → n, else 0. Mirrors Go's parseSince.
fn parseSince(req: *Request) usize {
    if (header(req, "last-event-id")) |lei| {
        const t = std.mem.trim(u8, lei, " \t");
        if (std.fmt.parseInt(usize, t, 10)) |n| return n + 1 else |_| {}
    }
    if (queryValue(req.head.target, "since")) |q| {
        if (std.fmt.parseInt(usize, q, 10)) |n| return n else |_| {}
    }
    return 0;
}

// ── raw + index ──────────────────────────────────────────────────────────────

/// rawTranscript serves the literal on-disk .md bytes (text/plain, nosniff) —
/// byte-for-byte parity with Go's serveRawTranscript.
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

/// indexPage lists the conversations this user can see — DMs they participate in
/// and channels they're a member of — each linking to its default topic.
fn indexPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, index_head);

    try b.appendSlice(alloc, "<h2>Direct messages</h2><ul>");
    var any_dm = false;
    if (Io.Dir.cwd().openDir(io, store.chat_root, .{ .iterate = true })) |*dir_const| {
        var dir = dir_const.*;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!try store.chatKeyParticipant(alloc, entry.name, uid)) continue;
            const conv = try alloc.dupe(u8, entry.name);
            const partner = try partnerName(io, alloc, conv, uid);
            try b.print(alloc, "<li><a href=\"/chat/c/{s}\">{s}</a> <span class=\"muted\">({s})</span></li>", .{
                conv, try htmlEscape(alloc, partner), conv,
            });
            any_dm = true;
        }
    } else |_| {}
    if (!any_dm) try b.appendSlice(alloc, "<li class=\"muted\">none</li>");
    try b.appendSlice(alloc, "</ul>");

    try b.appendSlice(alloc, "<h2>Channels</h2><ul>");
    var any_ch = false;
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        try b.print(alloc, "<li><a href=\"/channel/{s}\">#{s}</a></li>", .{ name, try htmlEscape(alloc, name) });
        any_ch = true;
    }
    if (!any_ch) try b.appendSlice(alloc, "<li class=\"muted\">none</li>");
    try b.appendSlice(alloc, "</ul></main></body></html>");

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
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

/// formField pulls one application/x-www-form-urlencoded field from `body`,
/// percent/plus-decoded, or null when absent. Field names here ("markdown",
/// "cid") are literal, so only the value is decoded.
fn formField(alloc: Alloc, body: []const u8, name: []const u8) !?[]const u8 {
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

/// queryValue pulls one (un-decoded) query parameter from a raw request target.
fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn header(req: *Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// replaceSeq returns `input` with every `needle` replaced by `repl` (alloc-owned).
fn replaceSeq(alloc: Alloc, input: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, input, needle, repl);
    const out = try alloc.alloc(u8, n);
    _ = std.mem.replace(u8, input, needle, repl, out);
    return out;
}

/// htmlEscape mirrors Go's html.EscapeString: & ' < > " → &amp; &#39; &lt; &gt; &#34;.
fn htmlEscape(alloc: Alloc, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "&'<>\"") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '\'' => try out.appendSlice(alloc, "&#39;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&#34;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

// ── templates (reproducing Go's platform chrome + chat shell) ─────────────────

// page_head: PageHeadAndStyle with tabTitle "Chat" — doctype, <head>, the shared
// platform stylesheet (AppChromeCSS + base rules), and <body> open. Static (no
// format args), so the literal `%`/`{` in the CSS need no escaping.
const page_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>Chat</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 0; padding: 0;
    \\       display: flex; flex-direction: column; min-height: 100vh; }
    \\.app-body-wrap { flex: 1; max-width: 820px; margin: 32px auto; padding: 0 24px 60px;
    \\                 width: 100%; box-sizing: border-box; }
    \\.app-top { background: var(--cc-top-bar-bg, #f0ede4);
    \\           border-bottom: 1px solid var(--cc-top-bar-border, #c9bfa7);
    \\           padding: 8px 24px;
    \\           font-family: sans-serif; display: flex; justify-content: space-between;
    \\           align-items: baseline;
    \\           position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: var(--cc-accent, #000080); text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.app-top-user { font-size: 13px; color: var(--cc-body-muted-fg, #444); }
    \\.app-top-user a { color: var(--cc-accent, #000080); }
    \\.chat-top .chat-top-left { display: flex; align-items: baseline; gap: 14px;
    \\                           flex-wrap: wrap; min-width: 0; }
    \\.chat-top-home { color: var(--cc-accent, #000080); text-decoration: none; font-size: 13px; }
    \\.chat-top-home:hover { text-decoration: underline; }
    \\.chat-top-title { font-weight: bold; color: var(--cc-accent, #000080); }
    \\.chat-top-links { font-size: 13px; }
    \\.chat-top-links a { color: var(--cc-accent, #000080); text-decoration: none; }
    \\.chat-top-links a:hover { text-decoration: underline; }
    \\.chat-notify { font-size:13px; color:var(--cc-notify-fg, #1a5fb4); overflow:hidden; text-overflow:ellipsis;
    \\               white-space:nowrap; min-width:0; }
    \\.chat-notify a { color:inherit; }
    \\.chat-notify a:hover { text-decoration:underline; }
    \\h1 { color: var(--cc-accent, #000080); }
    \\a { color: var(--cc-accent, #000080); }
    \\.muted { color: var(--cc-muted-fg, #888); }
    \\</style>
    \\</head><body>
    \\
;

// head_scripts: colors.js (sync, sets palette pre-paint) + chat_theme.js
// (deferred toggle wiring). Two {s} = asset version.
const head_scripts =
    \\<script src="/chat/colors.js?v={s}"></script><script>ChatColors.install();</script><script defer src="/chat/chat_theme.js?v={s}"></script>
;

// chrome_top: chatChromeTop with active="" (no nav link bolded, no admin link).
// {s} = escaped conversation title, {s} = escaped viewer name.
const chrome_top =
    \\<header class="app-top chat-top"><div class="chat-top-left"><a class="chat-top-home" href="/">Home</a><span class="chat-top-title">{s}</span><span class="chat-top-links"><a href="/chat">Chat</a> · <a href="/chat/docs">Docs</a> · <a href="/chat/recent">Recent</a> · <a href="/chat/images">Images</a> · <a href="/chat/code">Code</a> · <a href="/settings">Settings</a></span></div><div class="app-top-user"><button id="chat-theme-toggle" type="button" title="Toggle theme" aria-label="Toggle theme" style="background:none;border:none;cursor:pointer;font-size:16px;padding:0 8px;vertical-align:middle">🌙</button> · <strong>{s}</strong> · <a href="/learn">Learn</a> · <a href="/logout">Log out</a></div></header>
;

// chat_css: the page-shell layout (Go's chatCSS) — only the rules that span
// <html> down to .chat-layout; per-widget CSS is injected by the JS modules.
const chat_css =
    \\<style>
    \\html, body { height:100%; }
    \\.app-body-wrap { margin:10px auto; padding:0 24px 10px; min-height:0;
    \\                 max-width:none; display:flex; flex-direction:column; }
    \\#chat-root { flex:1; min-height:0; display:flex; flex-direction:column; }
    \\.chat-layout { display:flex; flex-direction:row; align-items:stretch;
    \\               gap:20px; flex:1; min-height:0; }
    \\</style>
;

const index_head =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>Conversations</title>
    \\<style>
    \\  body { font: 15px/1.6 system-ui, sans-serif; margin: 0; background: #f4f4ec; color: #222; }
    \\  main { max-width: 40rem; margin: 0 auto; padding: 1.5rem 1.25rem 4rem; }
    \\  h1 { font-size: 1.25rem; color: #000080; }
    \\  h2 { font-size: 1rem; color: #000080; margin: 1.5rem 0 .4rem; }
    \\  nav.top { background: #000080; color: #fff; padding: 8px 16px; font-size: 13px; }
    \\  nav.top a { color: #fff; text-decoration: none; margin-right: 14px; }
    \\  ul { list-style: none; padding: 0; margin: 0; }
    \\  li { padding: 4px 0; }
    \\  a { color: #000080; }
    \\  .muted { color: #888; }
    \\</style></head><body>
    \\<nav class="top"><a href="/">← Home</a></nav>
    \\<main>
    \\<h1>Conversations</h1>
;
