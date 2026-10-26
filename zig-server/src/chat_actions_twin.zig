//! **THE OLD ZIG, KEPT AS THE ROC'S ORACLE** (roc-webbox docs/ROC-CHAT.md
//! C4, C3): a /chat or /channel request served as before the Roc took a
//! topic's reactions, react, pin and unpin (C4), and a conversation's
//! landing and a topic's page (C3): decided by the Zig parse the router
//! replaced (chat_route_twin.zig), and those served by their Zig handlers
//! as they were (reactions.zig `serveFile` and `handleReact`, chat.zig
//! `pinTopic` at angry-gopher dc3445e; chat.zig's landings and the page's
//! tail at ffe98f1; chat.zig's newTopic, chatDefault, chatConversations
//! and chatMsgLookup at 6324f7c). chat_router.zig runs it when a
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
const Now = @import("request_time.zig").Now;

const Request = std.http.Server.Request;
const Alloc = std.mem.Allocator;

pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8, channel: bool) !void {
    const now = chat_router.test_now orelse Now.read(io);
    var call: chat_router.Call = .{ .req = req, .io = io, .alloc = alloc, .bus = bus, .now = now };
    // A static script before the gate, asking nobody.
    const first = try chat_route_twin.decide(alloc, sub, channel, true);
    if (first == .serve and first.serve.route.family == .asset) return chat.serve(req, io, alloc, bus, "", first.serve.route, now);
    const member = chat_router.Call.member(&call);
    if (call.failed) |e| return e;
    const decision = try chat_route_twin.decide(alloc, sub, channel, member);
    switch (decision) {
        .redirect => |location| return http.redirect(req, location),
        .serve => |s| {
            if (s.presence) presence.markActiveAndBroadcast(io, alloc, bus, call.uid, now);
            const r = s.route;
            switch (r.family) {
                .default => return chatDefault(req, io, alloc, call.uid, now),
                .conversations => return chatConversations(req, io, alloc, call.uid, now),
                .msg => return chatMsgLookup(req, io, alloc, call.uid, r.rest),
                else => {},
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .new) {
                const f = (try chat.findConv(io, alloc, call.uid, r.family, r.key)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                return newTopic(req, io, alloc, bus, (try f.topic(alloc)).conv, call.uid, now);
            }
            if ((r.family == .dm or r.family == .channel) and r.part == .landing) {
                const f = (try chat.findConv(io, alloc, call.uid, r.family, r.key)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                const def = try chat_paths.firstTopic(io, alloc, f.dir);
                if (def.len == 0) return chat_page.noTopicsPage(req, io, alloc, call.uid, f.base, try chat.convTitle(io, alloc, call.uid, f));
                return http.redirect(req, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ f.base, def }));
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

/// handleReact answers POST /<…>/<sid>/react: validate the three fields, append
/// the event (which fans out live), 204. Bad input is a 400 with a one-line
/// reason; `msg` beyond the transcript's count is one of them.
fn handleReact(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, reactions.max_body_bytes)) orelse return;
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
    const topic_raw = (try chat.formField(alloc, body, "topic")) orelse "";
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
        return http.redirect(req, try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv}));
    }
    const sid = try chat_state.resumeTopic(io, alloc, uid, conv, now);
    return http.redirect(req, try std.fmt.allocPrint(alloc, "/chat/c/{s}/{s}", .{ conv, sid }));
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
            return redirectFound(req, try std.fmt.allocPrint(alloc, "/chat/c/{s}/{s}#msg-{s}", .{ conv, sid, id }));
        }
    }
    for (try chat_paths.listUserChannels(io, alloc, uid)) |name| {
        const dir = try chat_paths.channelConvDir(alloc, name);
        if (try convHasTopic(io, alloc, dir, sid)) {
            return redirectFound(req, try std.fmt.allocPrint(alloc, "/channel/{s}/{s}#msg-{s}", .{ name, sid, id }));
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
fn redirectFound(req: *Request, location: []const u8) !void {
    return req.respond("", .{
        .status = .found,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}
