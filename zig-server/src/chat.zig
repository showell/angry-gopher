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
//!                                      functions)
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
const Now = @import("request_time.zig").Now;
const limits = @import("limits.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const store = @import("chat_store.zig");
const html = @import("webbox").html;
// Escaping lives in html.zig, not here, so chat_chrome.zig and the non-chat
// pages (login, game, admin, …) escape without importing the chat dispatcher.
const htmlEscape = html.htmlEscape; // internal alias; the impl lives in html.zig
const chrome = @import("chat_chrome.zig");
const upload = @import("chat_upload.zig");
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// Max bytes for one posted message.
const max_message_bytes = limits.body.chat_message;

// Resolved-conversation domain types (Conv, Topic) live in chat_conv.zig.
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
pub fn serve(
    req: *Request,
    io: Io,
    alloc: Alloc,
    uid: []const u8,
    route: Route,
) !void {
    switch (route.family) {
        // Embedded JS assets are public (static client code): the router
        // sends them here before the gate.
        .asset => return serveAsset(req, route.rest),
        // Bare /chat resumes you straight into your last conversation, or
        // shows the empty-state page if you have none; every "Chat" link
        // across the site points here.
        // /chat, the conversations, a message's link: the Roc's (roc-webbox
        // chat/main.roc), served before Zig is reached.
        .default, .conversations, .msg => std.debug.panic(
            "chat.serve: {t} is the Roc's",
            .{route.family},
        ),
        // /chat/recent, /images, /code and their streams: the Roc's
        // (roc-webbox chat/main.roc `member_stream!`, metal-vmm QUEUE 286);
        // /chat/docs[/...] too (`docs!`, metal-vmm QUEUE 289, 290).
        .recent, .images, .code, .docs => std.debug.panic(
            "chat.serve: {t} is the Roc's",
            .{route.family},
        ),
        // /chat/links: the Roc's (roc-webbox chat/main.roc `serve_rendered!`).
        .links => std.debug.panic("chat.serve: /chat/links is the Roc's", .{}),
        // /chat/search/words and /messages are the Roc's (metal-vmm QUEUE
        // 281, 282); nothing else under /chat/search is.
        .search => return http.notFound(req),
        .dm => return convRoute(
            req,
            io,
            alloc,
            uid,
            route,
        ),
        .channel => return channelRoute(
            req,
            io,
            alloc,
            uid,
            route,
        ),
        // The two cross-page attention streams, and the 404 of a path that
        // names nothing: the Roc's (metal-vmm QUEUE 286).
        .notifications, .sidebar_stream, .not_found => std.debug.panic(
            "chat.serve: {t} is the Roc's",
            .{route.family},
        ),
    }
}

// ── the lookup's pure decisions (the Roc's twins: chat/Conversation.roc) ──

/// channelRoute serves a tail of /channel/<name>/<topic> the Roc handed
/// back (roc-webbox chat/main.roc `serve_conversation!`): it found the
/// channel the viewer's and the topic there, and answered every 404.
/// **A FLOOR, NOT A DECISION**: the name must still be a channel's, so its
/// folder is under the chat root; anything else is the Roc's mistake, the
/// request's failure, never a page.
fn channelRoute(
    req: *Request,
    io: Io,
    alloc: Alloc,
    uid: []const u8,
    route: Route,
) !void {
    if (!chat_paths.validChannelName(route.key) or route.part != .topic) return error.NotAHandedBackTail;
    const conv = Conv{
        .meta = .{ .kind = .channel, .members = &.{} },
        .key = route.key,
        .base = try std.fmt.allocPrint(
            alloc,
            "/channel/{s}",
            .{route.key},
        ),
        .dir = try chat_paths.channelConvDir(alloc, route.key),
    };
    return topicRoute(
        req,
        io,
        alloc,
        route,
        uid,
        .{
            .conv = conv,
            .sid = route.topic,
            .title = "",
        },
    );
}

/// convRoute serves a tail of /chat/c/<pair>/<topic> the Roc handed back,
/// as channelRoute does: the key must still be a canonical pair, the
/// viewer one of it.
fn convRoute(
    req: *Request,
    io: Io,
    alloc: Alloc,
    uid: []const u8,
    route: Route,
) !void {
    const pair = route.key;
    if (!try chat_paths.chatKeyParticipant(
        alloc,
        pair,
        uid,
    ) or route.part != .topic) return error.NotAHandedBackTail;
    const us = std.mem.indexOfScalar(
        u8,
        pair,
        '_',
    ).?;
    const conv = Conv{
        .meta = try store.ConvMeta.dm(
            alloc,
            pair[0..us],
            pair[us + 1 ..],
        ),
        .key = pair,
        .base = try std.fmt.allocPrint(
            alloc,
            "/chat/c/{s}",
            .{pair},
        ),
        .dir = try chat_paths.dmConvDir(alloc, pair),
    };
    return topicRoute(
        req,
        io,
        alloc,
        route,
        uid,
        .{
            .conv = conv,
            .sid = route.topic,
            .title = "",
        },
    );
}

/// topicRoute serves the tails of a topic the Roc found the viewer's and handed
/// back: its uploads, an upload, its stream, its download and its saved ids.
fn topicRoute(
    req: *Request,
    io: Io,
    alloc: Alloc,
    route: Route,
    uid: []const u8,
    topic: Topic,
) !void {
    const conv = topic.conv;
    switch (route.tail) {
        .page => std.debug.panic(
            "chat.topicRoute: the page is the Roc's, and its topic was here",
            .{},
        ),
        // An upload and the bundle: the Roc's decision, the host's bytes
        // (roc-webbox chat/main.roc `serve_upload!`, `serve_download!`,
        // metal-vmm QUEUE 291).
        .uploads, .download => std.debug.panic(
            "chat.topicRoute: {t} is the Roc's, and its topic was here",
            .{route.tail},
        ),
        // The topic's stream: the Roc's decision, the router's to hold
        // (chat_router.zig `.stream`, metal-vmm QUEUE 286).
        .stream => std.debug.panic(
            "chat.topicRoute: a stream is the Roc's",
            .{},
        ),
        // A send: the Roc's (roc-webbox chat/main.roc `send!`), handed back
        // only when the conversation was not found, which was answered above.
        .send, .invalid_send => std.debug.panic(
            "chat.topicRoute: a send is the Roc's, and its conversation was here",
            .{},
        ),
        .upload => try upload.handleUpload(
            req,
            io,
            alloc,
            uid,
            conv.dir,
            conv.base,
            topic.sid,
        ),
        // The Roc's (roc-webbox chat/main.roc `act!`, docs/ROC-CHAT.md C4):
        // it hands one back only when its `find!` or the topic did not, and that
        // was answered above.
        .pin, .unpin, .reactions, .react => std.debug.panic(
            "chat.topicRoute: {t} is the Roc's, and its topic was here",
            .{route.tail},
        ),
        // The Roc's (chat/main.roc `act!`), handed back only when the topic
        // was not found, which was answered above.
        .raw => std.debug.panic("chat.topicRoute: raw is the Roc's, and its topic was here", .{}),
        // The Roc's (roc-webbox chat/main.roc `serve_saved!`).
        .saved => std.debug.panic("chat.topicRoute: saved is the Roc's", .{}),
        // No tail served here, or one with segments after it: the Roc's 404.
        .invalid => std.debug.panic("chat.topicRoute: an invalid tail is the Roc's", .{}),
    }
}

// ── send (write path) ────────────────────────────────────────────────────────

// ── assets ───────────────────────────────────────────────────────────────────

/// serveAsset serves an embedded client bundle by file name (no leading slash).
fn serveAsset(req: *Request, name: []const u8) !void {
    for (chrome.assets) |a| {
        if (std.mem.eql(
            u8,
            a.name,
            name,
        )) {
            return http.serveEmbedded(
                req,
                a.body,
                http.js_ct,
            );
        }
    }
    return http.notFound(req);
}

// ── small helpers ─────────────────────────────────────────────────────────────

/// formField pulls one application/x-www-form-urlencoded field from `body`,
/// percent/plus-decoded, or null when absent. Field names here ("markdown",
/// "cid") are literal, so only the value is decoded.
pub fn formField(
    alloc: Alloc,
    body: []const u8,
    name: []const u8,
) !?[]const u8 {
    return http.formField(
        alloc,
        body,
        name,
    );
}

/// urlDecode is `http.formDecode`: one decoder for every form.
pub fn urlDecode(alloc: Alloc, s: []const u8) ![]u8 {
    return http.formDecode(alloc, s);
}
