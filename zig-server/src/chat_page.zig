//! chat_page: the chat subsystem's HTML pages — the conversation view, the
//! first-topic bootstrap shell, the /chat index, and the inline sidebar payload
//! they boot with. The "skeleton" half of chat.zig: it owns the page DOM, the
//! chat-specific CSS overrides, and the bundle list, and leans on chat_chrome.zig for
//! the shared shell. chat.zig (the dispatcher) calls in here; nothing here calls
//! back, so the dependency is one-way.

const std = @import("std");
const chat_upload = @import("chat_upload.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const chat_state = @import("chat_state.zig");
const presence = @import("presence.zig");
const html = @import("webbox").html;
const chrome = @import("chat_chrome.zig");
const Topic = @import("chat_conv.zig").Topic;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;
const htmlEscape = html.htmlEscape; // internal alias; impl in html.zig

/// The sibling bundles the conversation page loads, in document order (after the
/// head's colors.js + chat_theme.js).
const page_scripts = [_][]const u8{
    "chat_image_popup.js",   "chat_code_popup.js", "chat_time_popup.js",
    "chat_save_popup.js",    "message.js",         "message_view.js",
    "nav_stack.js",          "middle_pane.js",     "chat_search.js",
    "chat_drag_to_pin.js",   "chat_add_topic.js",  "chat_left_sidebar.js",
    "chat_right_sidebar.js", "chat_emoji.js",      "chat_reactions.js",
    "chat_compose.js",       "chat_help.js",       "chat_responsive.js",
    "chat.js",               "notify.js",
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
    var page = try chrome.page(alloc, "Chat", title, viewer, "chat");
    const b = &page.body;
    try b.print(alloc, "<div id=\"chat-first-topic\" data-conv-base=\"{s}\"></div>", .{try htmlEscape(alloc, base)});
    try b.appendSlice(alloc, try chrome.script(alloc, "chat_add_topic.js"));
    try b.appendSlice(alloc, try chrome.script(alloc, "chat_first_topic.js"));
    try page.send(req, .ok);
}

/// **A 404 THAT SAYS WHY** (metal-vmm QUEUE 156(j)): `what` names what is not
/// there, and `back` is where to go instead. A page, not a bare "not found".
pub fn notFoundPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, what: []const u8, back: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    var page = try chrome.page(alloc, "Chat", "Not here", viewer, "chat");
    const b = &page.body;
    try b.print(alloc, "<p>{s}</p><p><a href=\"{s}\">Go back</a></p>", .{ try htmlEscape(alloc, what), try htmlEscape(alloc, back) });
    try page.send(req, .not_found);
}

// ── the conversation page (boots the prod JS) ────────────────────────────────

pub fn conversationPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, topic: Topic) !void {
    const conv = topic.conv;
    // Remember where this user is — the /chat/default resume pointer, keyed by
    // pair. Only convs that persist a cursor (DMs) do this; channels don't.
    if (conv.persistsCursor()) try chat_state.setUserLastSession(io, alloc, uid, conv.key, topic.sid);
    const viewer = try users.getUserName(io, alloc, uid);
    const sidebar_json = try buildSidebarJSON(io, alloc, uid, topic);

    var page = try chrome.page(alloc, "Chat", topic.title, viewer, "");
    // doctype + <head> + platform style + colors/theme scripts + top bar +
    // open .app-body-wrap. active="" so no nav link is bolded inside a conv.
    const b = &page.body;

    try b.appendSlice(alloc, chat_css);
    // data-me: the viewer's uid, so the client can tell its own reactions apart.
    // data-upload-*: the server's caps and accepted types, the client's only
    // copy (metal-vmm QUEUE 157(d)).
    try b.print(alloc, "<div id=\"chat-root\" data-conv=\"{s}\" data-conv-base=\"{s}\" data-session=\"{s}\" data-me=\"{s}\" data-upload-image-max=\"{d}\" data-upload-video-max=\"{d}\" data-upload-accept=\"{s}\" data-search-min=\"{d}\">", .{
        try htmlEscape(alloc, conv.key), try htmlEscape(alloc, conv.base), try htmlEscape(alloc, topic.sid), try htmlEscape(alloc, uid),
        chat_upload.image_max,           chat_upload.video_max,            chat_upload.accept,               @import("search_tokens.zig").min_len,
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
    inline for (page_scripts) |name| try b.appendSlice(alloc, try chrome.script(alloc, name));
    try page.send(req, .ok);
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

// ── the "no conversations" landing (replaces the old /chat index) ─────────────

/// noConversationsPage is the empty state for /chat: the standard chrome shell
/// with a plain message, rendered when the viewer has no conversation to resume.
/// We don't yet enforce that every member has SOME conversation, so this is the
/// honest empty case — a real page, not a redirect into a half-real index.
pub fn noConversationsPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    var page = try chrome.page(alloc, "Chat", "Chat", viewer, "chat");
    const b = &page.body;
    try b.appendSlice(alloc, "<p>You do not have any conversations.</p>");
    try page.send(req, .ok);
}

// ── chat-specific templates (shared chrome lives in chat_chrome.zig) ──────────────

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
