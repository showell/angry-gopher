//! chat_page: the chat subsystem's HTML pages — the conversation view, the
//! first-topic bootstrap shell, the /chat index, and the inline sidebar payload
//! they boot with. The "skeleton" half of chat.zig: it owns the page DOM, the
//! chat-specific CSS overrides, and the bundle list, and leans on chrome.zig for
//! the shared shell. chat.zig (the dispatcher) calls in here; nothing here calls
//! back, so the dependency is one-way.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const chat_state = @import("chat_state.zig");
const presence = @import("presence.zig");
const html = @import("html.zig");
const chrome = @import("chrome.zig");
const Topic = @import("conv.zig").Topic;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;
const htmlEscape = html.htmlEscape; // internal alias; impl in html.zig
const asset_v = chrome.asset_v; // internal alias; canonical const in chrome.zig

/// The sibling bundles the conversation page loads, in document order (after the
/// head's colors.js + chat_theme.js).
const page_scripts = [_][]const u8{
    "chat_image_popup.js", "chat_code_popup.js",   "chat_time_popup.js",
    "chat_save_popup.js",
    "message.js",          "message_view.js",      "nav_stack.js",
    "middle_pane.js",      "chat_search.js",       "chat_drag_to_pin.js",
    "chat_add_topic.js",   "chat_left_sidebar.js", "chat_right_sidebar.js",
    "chat_compose.js",     "chat_help.js",         "chat_responsive.js",
    "chat.js",
    "notify.js",
};

/// firstTopicPage renders the "no topics yet" bootstrap shell for a conversation
/// that is addressable (a DM pair, or a channel the viewer is in) but has no
/// sessions on disk. The shell is deliberately thin: chrome + an empty mount
/// carrying the conv base; the ChatFirstTopic client module owns the intro, the
/// styling, and the ChatAddTopic widget (pre-filled "general") that POSTs
/// <base>/new and navigates to the created topic. `base` is "/chat/c/<pair>" or
/// "/channel/<name>"; the widget is base-shape-agnostic.
pub fn firstTopicPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, base: []const u8, title: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    var b: std.ArrayList(u8) = .empty;
    try chrome.begin(&b, alloc, "Chat", title, viewer, "chat");
    try b.print(alloc, "<div id=\"chat-first-topic\" data-conv-base=\"{s}\"></div>", .{try htmlEscape(alloc, base)});
    try b.print(alloc, "<script src=\"/chat/chat_add_topic.js?v={s}\"></script>", .{asset_v});
    try b.print(alloc, "<script src=\"/chat/chat_first_topic.js?v={s}\"></script>", .{asset_v});
    try chrome.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// ── the conversation page (boots the prod JS) ────────────────────────────────

pub fn conversationPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, topic: Topic) !void {
    const conv = topic.conv;
    // Remember where this user is — the /chat/default resume pointer, keyed by
    // pair. Only convs that persist a cursor (DMs) do this; channels don't.
    if (conv.persistsCursor()) chat_state.setUserLastSession(io, alloc, uid, conv.key, topic.sid);
    const viewer = try users.getUserName(io, alloc, uid);
    const sidebar_json = try buildSidebarJSON(io, alloc, uid, topic);

    var b: std.ArrayList(u8) = .empty;
    // doctype + <head> + platform style + colors/theme scripts + top bar +
    // open .app-body-wrap. active="" so no nav link is bolded inside a conv.
    try chrome.begin(&b, alloc, "Chat", topic.title, viewer, "");

    try b.appendSlice(alloc, chat_css);
    try b.print(alloc, "<div id=\"chat-root\" data-conv=\"{s}\" data-conv-base=\"{s}\" data-session=\"{s}\">", .{
        try htmlEscape(alloc, conv.key), try htmlEscape(alloc, conv.base), try htmlEscape(alloc, topic.sid),
    });
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div class=\"chat-layout\">");

    // left-rail mount + the inline sidebar payload (first paint, no round-trip).
    try b.appendSlice(alloc, "<div id=\"chat-left-sidebar\"></div>");
    try b.print(alloc, "<script type=\"application/json\" id=\"chat-sidebar-data\">{s}</script>", .{sidebar_json});

    try b.appendSlice(alloc, "<div id=\"chat-feed\"></div>");
    try b.appendSlice(alloc, "<div id=\"chat-right-sidebar\"></div></div>");

    // sibling bundles, in document order, then close #chat-root + the chrome.
    try b.appendSlice(alloc, "</div>");
    for (page_scripts) |name| {
        try b.print(alloc, "<script src=\"/chat/{s}?v={s}\"></script>", .{ name, asset_v });
    }
    try chrome.end(&b, alloc);

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// buildSidebarJSON is the inline left-rail payload:
/// conversations = every other authorized user (DM) + every channel the viewer
/// is in; pinned_sessions = [] (pins not ported yet); sessions = this conv's
/// topics. The `</`→`<\/` pass is script-tag safety for inline embedding.
fn buildSidebarJSON(io: Io, alloc: Alloc, uid: []const u8, topic: Topic) ![]const u8 {
    const conv = topic.conv;
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, "{\"conversations\":[");

    var first = true;
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, uid)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        const pk = try store.chatPairKey(alloc, uid, u.id);
        const active = conv.meta.kind == .dm and std.mem.eql(u8, pk, conv.key);
        try b.print(alloc, "{{\"id\":\"uid:{s}\",\"label\":{f},\"url\":\"/chat/c/{s}\",\"active\":{}", .{
            u.id, std.json.fmt(u.name, .{}), pk, active,
        });
        // online (omitted when false) — drives the partner row's first-paint dot.
        if (presence.isOnline(io, u.id)) try b.appendSlice(alloc, ",\"online\":true");
        try b.append(alloc, '}');
    }
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        if (!first) try b.append(alloc, ',');
        first = false;
        const active = conv.meta.kind == .channel and std.mem.eql(u8, name, conv.key);
        const label = try std.fmt.allocPrint(alloc, "# {s}", .{name});
        try b.print(alloc, "{{\"id\":\"ch:{s}\",\"label\":{f},\"url\":\"/channel/{s}\",\"active\":{}}}", .{
            name, std.json.fmt(label, .{}), name, active,
        });
    }

    // Sessions split by pinned state: the conv's
    // pins (conv-key form) intersect the live session list — stale ids drop out.
    const pins = try chat_state.pinnedSessions(io, alloc, uid, conv.key);
    const sessions = try store.listSessions(io, alloc, conv.dir);

    try b.appendSlice(alloc, "],\"pinned_sessions\":[");
    first = true;
    for (sessions) |s| {
        if (!chat_state.isPinned(pins, s)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        try emitSessionItem(&b, alloc, conv.base, s, topic.sid);
    }
    try b.appendSlice(alloc, "],\"sessions\":[");
    first = true;
    for (sessions) |s| {
        if (chat_state.isPinned(pins, s)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        try emitSessionItem(&b, alloc, conv.base, s, topic.sid);
    }
    try b.appendSlice(alloc, "]}");

    return html.scriptSafe(alloc, b.items);
}

/// emitSessionItem appends one session row (`{id,label,url,active}`) to the
/// sidebar JSON — shared by the pinned and unpinned passes.
fn emitSessionItem(b: *std.ArrayList(u8), alloc: Alloc, base: []const u8, s: []const u8, sid: []const u8) !void {
    const active = std.mem.eql(u8, s, sid);
    const u = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, s });
    try b.print(alloc, "{{\"id\":{f},\"label\":{f},\"url\":{f},\"active\":{}}}", .{
        std.json.fmt(s, .{}), std.json.fmt(s, .{}), std.json.fmt(u, .{}), active,
    });
}

// ── the /chat index (no conv selected) ───────────────────────────────────────

/// indexPage lists the conversations this user can see — DMs they participate in
/// and channels they're a member of — each linking to its default topic.
pub fn indexPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, index_head);

    // List every OTHER authorized principal as a startable DM — not just convs
    // that already exist on disk. A DM directory is created lazily (first topic),
    // so a fresh member would otherwise see "none" with no way in; clicking a
    // partner with no topics yet lands on the first-topic bootstrap page. "none"
    // now means exactly what it says: you're the only principal.
    try b.appendSlice(alloc, "<h2>Direct messages</h2><ul>");
    var any_dm = false;
    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        const conv = try store.chatPairKey(alloc, uid, partner.id);
        try b.print(alloc, "<li><a href=\"/chat/c/{s}\">{s}</a></li>", .{
            conv, try htmlEscape(alloc, partner.name),
        });
        any_dm = true;
    }
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

// ── chat-specific templates (shared chrome lives in chrome.zig) ──────────────

// chat_css: the page-shell layout — only the rules that span <html> down to
// .chat-layout; per-widget CSS is injected by the JS modules. The .app-body-wrap
// override here makes the conversation page full-width (vs chrome's default
// content column).
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

// index_head: the standalone /chat landing-page head — its own simple layout
// (a <main> column, blue top nav), not the shared chrome.
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
