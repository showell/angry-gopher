//! **THE OLD ZIG, KEPT AS THE ROC'S ORACLE** (roc-webbox docs/ROC-CHAT.md
//! C4, C3): a /chat or /channel request served as before the Roc took a
//! topic's reactions, react, pin and unpin (C4), and a conversation's
//! landing and a topic's page (C3): decided by the Zig parse the router
//! replaced (chat_route_twin.zig), and those served by their Zig handlers
//! as they were (reactions.zig `serveFile` and `handleReact`, chat.zig
//! `pinTopic` at angry-gopher dc3445e; chat.zig's landings and the page's
//! tail at ffe98f1; chat.zig's newTopic, chatDefault, chatConversations
//! and chatMsgLookup at 6324f7c; sendMessage at 3037312; rawTranscript and
//! chat_links.zig at 51807d8; images.zig's and code.zig's pages at 91db93d;
//! recent.zig's page at 43fb217, from the rows it gathered then). chat_router.zig runs it when a
//! test sets `test_oracle`; chat_actions_twin_test.zig runs the same
//! requests both ways, on two copies of one tree, and holds the answers and
//! the files they leave to each other. Test-only: it goes when the Roc has
//! no more to prove.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const Bus = webbox.bus.Bus;
const roc_chat = @import("roc_chat");
const chat = @import("chat.zig");
const chat_router = @import("chat_router.zig");
const chat_route_twin = @import("chat_route_twin.zig");
const presence = @import("presence.zig");
const reactions = @import("reactions.zig");
const chat_state = @import("chat_state.zig");
const store = @import("chat_store.zig");
const chat_page = @import("chat_page.zig");
const chat_paths = @import("chat_paths.zig");
const users = @import("users.zig");
const decimal = @import("decimal.zig");
const limits = @import("limits.zig");
const Conv = @import("chat_conv.zig").Conv;
const Topic = @import("chat_conv.zig").Topic;
const markdown = @import("markdown.zig");
const edge = webbox.edge;
const chrome = @import("chat_chrome.zig");
const disk = webbox.store;
const html = webbox.html;
const chat_fanout = @import("chat_fanout.zig");
const images_store = @import("images_store.zig");
const code_store = @import("code_store.zig");
const recent = @import("recent.zig");
const recent_feed = @import("recent_feed.zig");
const timefmt = @import("timefmt.zig");
const Now = @import("request_time.zig").Now;

const Request = std.http.Server.Request;
const Alloc = std.mem.Allocator;

pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8, channel: bool) !void {
    const now = chat_router.test_now orelse Now.read(io);
    var call: chat_router.Call = .{ .req = req, .io = io, .alloc = alloc, .bus = bus, .now = now };
    // A static script before the gate, asking nobody.
    const first = try chat_route_twin.decide(alloc, sub, channel, true);
    if (first == .serve and first.serve.route.family == .asset) return chat.serve(req, io, alloc, bus, "", first.serve.route, now);
    const member = chat_router.Call.checkMember(&call) == .member;
    if (call.failed) |e| return e;
    const decision = try chat_route_twin.decide(alloc, sub, channel, member);
    switch (decision) {
        .redirect => |location| return http.redirect(req, try http.Target.format(alloc, "{s}", .{location})),
        .to_login => |next| return chat_router.toLogin(req, alloc, next),
        .serve => |s| {
            if (s.presence) presence.markActiveAndBroadcast(io, alloc, bus, call.uid, now);
            const r = s.route;
            switch (r.family) {
                .default => return chatDefault(req, io, alloc, call.uid, now),
                .conversations => return chatConversations(req, io, alloc, call.uid, now),
                .msg => return chatMsgLookup(req, io, alloc, call.uid, r.rest),
                .links => return linksPage(req, io, alloc, call.uid, r.rest),
                .recent => if (!std.mem.eql(u8, r.rest, "/stream")) {
                    if (r.rest.len != 0) return http.notFound(req);
                    return renderRecentPage(req, io, alloc, call.uid);
                },
                .images, .code => if (!std.mem.eql(u8, r.rest, "/stream")) {
                    if (r.rest.len != 0) return http.notFound(req);
                    return if (r.family == .images) renderImagesPage(req, io, alloc, call.uid) else renderCodePage(req, io, alloc, call.uid);
                },
                else => {},
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .topic and (r.tail == .send or r.tail == .invalid_send)) {
                var f = (try chat.findConv(io, alloc, call.uid, r.family, r.key)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                f.sid = r.topic;
                f.title = try chat.convTitle(io, alloc, call.uid, f);
                if (r.tail == .invalid_send) return http.notFound(req);
                return sendMessage(req, io, alloc, bus, try f.topic(alloc), call.uid, now);
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .new) {
                const f = (try chat.findConv(io, alloc, call.uid, r.family, r.key)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                return newTopic(req, io, alloc, bus, (try f.topic(alloc)).conv, call.uid, now);
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .landing) {
                const f = (try chat.findConv(io, alloc, call.uid, r.family, r.key)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                const def = try chat_paths.firstTopic(io, alloc, f.dir);
                if (def.len == 0) return chat_page.noTopicsPage(req, io, alloc, call.uid, f.base, try chat.convTitle(io, alloc, call.uid, f));
                return http.redirect(req, try http.Target.format(alloc, "{s}/{s}", .{ f.base, def }));
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .topic and r.tail == .page) {
                const t = (try chat.findTopic(io, alloc, call.uid, r)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                if (req.head.method != .GET and req.head.method != .HEAD) return http.methodNotAllowed(req, .GET);
                return chat_page.conversationPage(req, io, alloc, call.uid, try t.topic(alloc), now);
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .topic) switch (r.tail) {
                .reactions, .react, .pin, .unpin => {
                    // The 404s are chat.zig's, as ever.
                    const t = (try chat.findTopic(io, alloc, call.uid, r)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                    return switch (r.tail) {
                        .reactions => serveFile(req, io, alloc, t.dir, t.sid),
                        .react => handleReact(req, io, alloc, bus, t.dir, t.key, t.sid, call.uid, now),
                        .pin => pinTopic(req, io, alloc, call.uid, t.key, t.sid, true),
                        else => pinTopic(req, io, alloc, call.uid, t.key, t.sid, false),
                    };
                },
                .raw => {
                    const t = (try chat.findTopic(io, alloc, call.uid, r)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                    if (req.head.method != .GET and req.head.method != .HEAD) return http.methodNotAllowed(req, .GET);
                    return rawTranscript(req, io, alloc, t.dir, r.topic);
                },
                else => {},
            };
            return chat.serve(req, io, alloc, bus, call.uid, r, now);
        },
        else => unreachable,
    }
}

/// serveFile answers GET /<…>/<sid>/reactions with the sidecar's bytes.
fn serveFile(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const bytes = try store.readReactions(io, alloc, conv_dir, sid);
    try req.respond(bytes, .{ .extra_headers = &.{http.ndjson_ct} });
}

/// **A FORM IS TEXT AT THE ROC'S DOOR**, where chat.zig took its bytes: a
/// field that is not UTF-8 once decoded is a malformed form, the site's 400.
/// The twin refuses it the same way.
fn textField(alloc: Alloc, body: []const u8, name: []const u8) !?[]const u8 {
    const v = (try chat.formField(alloc, body, name)) orelse return null;
    if (!std.unicode.utf8ValidateSlice(v)) return error.MalformedForm;
    return v;
}

/// handleReact answers POST /<…>/<sid>/react: validate the three fields, append
/// the event (which fans out live), 204. Bad input is a 400 with a one-line
/// reason; `msg` beyond the transcript's count is one of them.
fn handleReact(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, reactions.max_body_bytes)) orelse return;
    for ([_][]const u8{ "msg", "emoji", "on" }) |name| _ = try textField(alloc, body, name);
    const r = switch (try reactions.parseReactForm(alloc, body)) {
        .bad => |why| return req.respond(why, .{ .status = .bad_request }),
        .reacted => |r| r,
    };
    switch (try reactions.storeReaction(io, alloc, bus, .{ .dir = conv_dir, .key = conv_key, .sid = sid }, uid, now, r)) {
        .stored => try req.respond("", .{ .status = .no_content }),
        .no_such_message => try req.respond("react: no such message\n", .{ .status = .bad_request }),
    }
}

/// pinTopic handles POST /<…>/<sid>/{pin,unpin}: toggle whether `sid` is in
/// the caller's per-conv Pinned group, then 204.
fn pinTopic(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8, pinned: bool) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    try chat_state.setTopicPinned(io, alloc, uid, conv_key, sid, pinned);
    return req.respond("", .{ .status = .no_content });
}

// ── new topic ─────────────────────────────────────────────────────────────────

/// newTopic handles POST <conv-base>/new:
/// validate the `topic` form field, refuse duplicates + the reserved "new", then
/// seed the topic with a first "hi" message (which fans out topic-added). For a
/// DM it also remembers the new topic as last-viewed and announces it as a link
/// in the highest generalN topic, where the partner already watches. Returns
/// `{conv, sid}` JSON. Shared by DMs and channels (kind gates the DM-only extras).
fn newTopic(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv: Conv, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);

    const body = (try http.readLimitedBody(req, alloc, limits.body.chat_message)) orelse return;
    const topic_raw = (try textField(alloc, body, "topic")) orelse "";
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
        if (try highestGeneralTopic(io, alloc, conv.dir)) |gen| {
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

/// highestGeneralTopic returns the "general<N>" topic with the largest N in
/// `dir`, or null when there is none.
fn highestGeneralTopic(io: Io, alloc: Alloc, dir: []const u8) !?[]const u8 {
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

/// chatDefault resumes the viewer's last conversation: read their last-conv
/// bookmark, resolve its landing topic, and 302 into /chat/c/<conv>/<sid>. It
/// backs both bare /chat and /chat/default. When there's no bookmark (or it names
/// a conv they no longer participate in), we render the "no conversations" page
/// rather than redirect — the invariant that everyone has SOME conversation isn't
/// enforced yet, so this is the honest empty state.
fn chatDefault(req: *Request, io: Io, alloc: Alloc, uid: []const u8, now: Now) !void {
    const conv = try chat_state.lastUserConv(io, alloc, uid);
    if (conv.len == 0 or !(try chat_paths.chatKeyParticipant(alloc, conv, uid))) {
        return chat_page.noConversationsPage(req, io, alloc, uid);
    }
    // A conversation with no topic yet lands on its own page, which offers to
    // start the first, where it went to today's date as a topic: a send makes
    // one there, but a page of a topic not there is a 404 (156(j)'s review).
    if ((try chat_paths.firstTopic(io, alloc, try chat_paths.dmConvDir(alloc, conv))).len == 0) {
        return http.redirect(req, try http.Target.format(alloc, "/chat/c/{s}", .{conv}));
    }
    const sid = try chat_state.resumeTopic(io, alloc, uid, conv, now);
    return http.redirect(req, try http.Target.format(alloc, "/chat/c/{s}/{s}", .{ conv, sid }));
}

/// chatConversations serves GET /chat/conversations: the (partner × topic)
/// matrix as JSON — every other authorized principal, each conv's default
/// landing topic and its topic list (sorted). The discovery entry point for
/// API-key clients.
fn chatConversations(req: *Request, io: Io, alloc: Alloc, uid: []const u8, now: Now) !void {
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

/// chatMsgLookup resolves a global MSG_<id> to the thread it lives in and 302s to
/// that topic URL + #msg-<id>. Walks the viewer's accessible convs (DM partners,
/// then channels) and picks the first whose topic list holds the sid embedded
/// in the id.
fn chatMsgLookup(req: *Request, io: Io, alloc: Alloc, uid: []const u8, id: []const u8) !void {
    if (!chat_paths.validMsgRefID(id)) return http.notFound(req);
    const cut = std.mem.lastIndexOfScalar(u8, id, '_').?; // validMsgRefID guarantees one
    const sid = id[0..cut];

    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        const conv = try chat_paths.chatPairKey(alloc, uid, partner.id);
        const dir = try chat_paths.dmConvDir(alloc, conv);
        if (try convHasTopic(io, alloc, dir, sid)) {
            return redirectFound(req, try http.Target.format(alloc, "/chat/c/{s}/{s}#msg-{s}", .{ conv, sid, id }));
        }
    }
    for (try chat_paths.listUserChannels(io, alloc, uid)) |name| {
        const dir = try chat_paths.channelConvDir(alloc, name);
        if (try convHasTopic(io, alloc, dir, sid)) {
            return redirectFound(req, try http.Target.format(alloc, "/channel/{s}/{s}#msg-{s}", .{ name, sid, id }));
        }
    }
    return http.notFound(req);
}

/// convHasTopic reports whether `dir`'s topic list contains `sid`.
fn convHasTopic(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) !bool {
    for (try chat_paths.listTopics(io, alloc, dir)) |s| {
        if (std.mem.eql(u8, s, sid)) return true;
    }
    return false;
}

/// redirectFound issues a 302 to `location` — the msg-ref
/// lookup uses 302 (a transient lookup-then-go), not the 303 the others use.
fn redirectFound(req: *Request, location: http.Target) !void {
    return http.redirectWith(req, location, .{ .status = .found });
}

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

    const body = (try http.readLimitedBody(req, alloc, limits.body.chat_message)) orelse return;
    const md = (try textField(alloc, body, "markdown")) orelse
        return req.respond("not sent: no message (the form has no markdown field)\n", .{ .status = .bad_request });
    const cid = (try textField(alloc, body, "cid")) orelse "";
    if (std.mem.trim(u8, md, " \t\r\n").len == 0) {
        return req.respond("not sent: the message is empty\n", .{ .status = .bad_request });
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

/// sendDone reports a send: 204 for async fetch callers, else a
/// 303 back to the topic page (the no-JS form-post fallback).
/// The answer to a stored send: allocates nothing, so a send stored is never
/// answered 500 for memory (177.1).
fn sendDone(req: *Request, is_async: bool, back: http.Target) !void {
    if (is_async) return req.respond("", .{ .status = .no_content });
    return http.redirect(req, back);
}

/// rawTranscript serves the literal on-disk .md bytes (text/plain, nosniff).
fn rawTranscript(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    const data = (try chat_paths.readTranscript(io, alloc, conv_dir, sid)) orelse return http.notFound(req);
    try req.respond(data, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

/// linksPage serves /chat/links — `rest` must be empty (no sub-routes).
fn linksPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, rest: []const u8) !void {
    if (rest.len != 0) return http.notFound(req);
    const viewer = try users.getUserName(io, alloc, uid);
    const path = try std.fs.path.join(alloc, &.{ store.chat_root, "users", uid, "links.md" });
    const md: ?[]u8 = try disk.readOrNull(io, alloc, path, .unlimited);

    var page = try chrome.page(alloc, "Links", "Links", viewer, "links");
    const b = &page.body;
    try b.appendSlice(alloc, links_css ++ "<div class=\"links-page\">");
    if (md) |src| {
        // renderTrusted: links.md is server-curated (Steve scp's it), not request
        // input, so it's exempt from render()'s hostile-token cap — a links page
        // has far more than 256 link tokens. Same pipeline otherwise.
        try b.appendSlice(alloc, try markdown.renderTrusted(alloc, src));
    } else {
        try b.appendSlice(alloc, "<p>No links yet — ask Steve to curate links.</p>");
    }
    try b.appendSlice(alloc, "</div>"); // close .links-page
    try page.send(req, .ok);
}

// A readable text column — .app-body-wrap is the full-width chat-layout shell,
// so this static page supplies its own narrow column. Tiny + scoped on purpose.
const links_css =
    \\<style>
    \\.links-page { max-width: 46rem; margin: 0 auto; line-height: 1.55; }
    \\.links-page h2 { margin-top: 1.6rem; }
    \\.links-page li { margin: 3px 0; }
    \\</style>
;

/// imagesPageLimit caps how many of the most-recent entries the page renders —
/// it's a "what got shared lately" feed and every entry is a full image, so the
/// tail keeps it light over a slow link.
const images_page_limit = 20;

fn renderImagesPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    var entries = try images_store.readImagesForUser(io, alloc, uid);
    // Oldest-first on disk; keep only the most-recent imagesPageLimit (the tail).
    if (entries.len > images_page_limit) entries = entries[entries.len - images_page_limit ..];

    var page = try chrome.page(alloc, "Images", "Images", viewer, "images");
    const b = &page.body;
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"images-mount\"></div>");
    try emitImagesData(b, alloc, entries);
    inline for (.{ "styles.js", "chat_image_popup.js", "images.js", "notify.js" }) |name| try b.appendSlice(alloc, try chrome.script(alloc, name));
    try page.send(req, .ok);
}

/// emitImagesData ships the initial transcript as inline JSON. The scriptSafe
/// pass (every `<` as `\u003c`) prevents the JSON from closing the surrounding <script>. Per-entry
/// source_url is rebuilt from the entry's conv.
fn emitImagesData(b: *std.ArrayList(u8), alloc: Alloc, entries: []images_store.ImagesEntry) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (entries, 0..) |e, i| {
        if (i != 0) try j.append(alloc, ',');
        const base = try chat_fanout.convKeyBaseURL(alloc, e.conv);
        const src = try images_store.imagesSourceURL(alloc, base, e.source_id);
        try images_store.encodeImagesEvent(&j, alloc, e, src);
    }
    try j.append(alloc, ']');
    const safe = try html.scriptSafe(alloc, j.items);
    try b.appendSlice(alloc, "<script id=\"images-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

fn renderCodePage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const entries = try code_store.readCodeForUser(io, alloc, uid);

    var page = try chrome.page(alloc, "Code", "Code", viewer, "code");
    const b = &page.body;
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"code-mount\"></div>");
    try emitCodeData(b, alloc, entries);
    inline for (.{ "styles.js", "chat_code_popup.js", "code.js", "notify.js" }) |name| try b.appendSlice(alloc, try chrome.script(alloc, name));
    try page.send(req, .ok);
}

/// emitCodeData ships the initial transcript as inline JSON. The scriptSafe pass (every `<` as `\u003c`)
/// prevents the JSON from closing the surrounding <script>. Per-entry source_url
/// is rebuilt from the entry's conv (shares images_store's helper).
fn emitCodeData(b: *std.ArrayList(u8), alloc: Alloc, entries: []code_store.CodeEntry) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (entries, 0..) |e, i| {
        if (i != 0) try j.append(alloc, ',');
        const base = try chat_fanout.convKeyBaseURL(alloc, e.conv);
        const src = try images_store.imagesSourceURL(alloc, base, e.source_id);
        try code_store.encodeCodeEvent(&j, alloc, e, src);
    }
    try j.append(alloc, ']');
    const safe = try html.scriptSafe(alloc, j.items);
    try b.appendSlice(alloc, "<script id=\"code-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

const Kind = enum { chat, doc };

/// RecentItem is one row before JSON encoding. `at_ns` (file mtime) is the sort
/// key; `at` is its RFC3339 rendering for the wire. Chat-only fields are
/// pre-resolved per viewer, so DM and channel rows are shaped identically.
pub const RecentItem = struct {
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

/// The items gatherRecentItems made of what it read (recent.zig `Row`):
/// "You" for the viewer, the date as RFC3339, a message's excerpt.
pub fn recentItems(alloc: Alloc, viewer: []const u8, rows: []const recent.Row) ![]RecentItem {
    var items: std.ArrayList(RecentItem) = .empty;
    for (rows) |w| {
        const at_ns = @as(i96, w.secs) * std.time.ns_per_s;
        const at = try timefmt.formatRFC3339UTC(alloc, w.secs);
        if (w.doc) {
            try items.append(alloc, .{ .kind = .doc, .at_ns = at_ns, .at = at, .who = "You", .slug = w.key, .title = w.label });
            continue;
        }
        const who = if (w.uid.len == 0) "" else if (std.mem.eql(u8, w.uid, viewer)) "You" else w.name;
        try items.append(alloc, .{ .kind = .chat, .at_ns = at_ns, .at = at, .who = who, .url = w.key, .where = w.label, .topic = w.topic, .excerpt = try recent_feed.recentExcerpt(alloc, w.markdown), .dm = w.dm });
    }
    const slice = try items.toOwnedSlice(alloc);
    std.mem.sort(RecentItem, slice, {}, newestFirst);
    return slice;
}

/// newestFirst orders the feed. **A TIE IS BROKEN BY THE URL**, because a
/// message's date is recorded to the second: two topics written inside one
/// second must still come out in the same order on every host that serves this
/// data, or the two builds of this application would disagree about a page.
fn newestFirst(_: void, a: RecentItem, b: RecentItem) bool {
    if (a.at_ns != b.at_ns) return a.at_ns > b.at_ns;
    const ka = if (a.url.len > 0) a.url else a.slug;
    const kb = if (b.url.len > 0) b.url else b.slug;
    return std.mem.lessThan(u8, ka, kb);
}

fn renderRecentPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const items = try recentItems(alloc, uid, try recent.gatherRows(io, alloc, uid));

    var page = try chrome.page(alloc, "Recent", "Recent", viewer, "recent");
    const b = &page.body;
    // Cross-page attention strip + favicon alert on incoming pings (notify.js
    // no-ops when #chat-notify is absent). Recent users camp here, so the tab
    // needs to alert too.
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"recent-mount\"></div>");
    try emitRecentData(b, alloc, items);
    inline for (.{ "recent.js", "notify.js" }) |name| try b.appendSlice(alloc, try chrome.script(alloc, name));
    try page.send(req, .ok);
}

/// recentJSON: the feed as the page ships it, before the script-safe pass.
pub fn recentJSON(alloc: Alloc, items: []RecentItem) ![]u8 {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (items, 0..) |it, i| {
        if (i != 0) try j.append(alloc, ',');
        switch (it.kind) {
            .chat => try recent_feed.encodeChatEvent(&j, alloc, .{ .at = it.at, .url = it.url, .who = it.who, .where = it.where, .topic = it.topic, .excerpt = it.excerpt, .dm = it.dm }),
            .doc => try recent_feed.encodeDocEvent(&j, alloc, it.at, it.who, it.slug, it.title),
        }
    }
    try j.append(alloc, ']');
    return j.items;
}

/// emitRecentData ships the initial feed as inline JSON next to the mount slot.
/// The scriptSafe pass (every `<` as `\u003c`) prevents the JSON from closing the surrounding <script>.
fn emitRecentData(b: *std.ArrayList(u8), alloc: Alloc, items: []RecentItem) !void {
    const safe = try html.scriptSafe(alloc, try recentJSON(alloc, items));
    try b.appendSlice(alloc, "<script id=\"recent-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}
