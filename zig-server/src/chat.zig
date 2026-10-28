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
//!   .../<sid>/{upload,uploads,download,saved}   the Roc's (roc-webbox chat/main.roc)
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
const http = @import("webbox").http;
const chrome = @import("chat_chrome.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

// ── serving a route ───────────────────────────────────────────────────────

const roc_chat = @import("roc_chat");
const Route = roc_chat.Route;

/// serve answers a /chat or /channel request where the Roc router sent it
/// (chat_router.zig, which ran the prelude: the static scripts, the gate,
/// presence). `route` is the path as the router parsed it; nothing here
/// reads the path again. Only the embedded assets and /chat/search's 404
/// are left here; every other route is the Roc's.
pub fn serve(req: *Request, route: Route) !void {
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
        // Every route of a DM or a channel, the last of them a topic's
        // upload (roc-webbox chat/main.roc `post_upload!`, metal-vmm QUEUE 292).
        .dm, .channel => std.debug.panic(
            "chat.serve: {t} is the Roc's",
            .{route.family},
        ),
        // The two cross-page attention streams, and the 404 of a path that
        // names nothing: the Roc's (metal-vmm QUEUE 286).
        .notifications, .sidebar_stream, .not_found => std.debug.panic(
            "chat.serve: {t} is the Roc's",
            .{route.family},
        ),
    }
}

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
