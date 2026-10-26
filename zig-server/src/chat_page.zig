//! chat_page: the chat subsystem's HTML pages — the conversation view, the
//! first-topic bootstrap shell, the /chat index, and the inline sidebar payload
//! they boot with. The "skeleton" half of chat.zig: it owns the page DOM, the
//! chat-specific CSS overrides, and the bundle list, and leans on chat_chrome.zig for
//! the shared shell. chat.zig (the dispatcher) calls in here; nothing here calls
//! back, so the dependency is one-way.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const Now = @import("request_time.zig").Now;
const chat_upload = @import("chat_upload.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const users = @import("users.zig");
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

/// noTopicsPage renders the "no topics yet" bootstrap shell for a conversation
/// that is addressable (a DM pair, or a channel the viewer is in) but has no
/// topics on disk. The shell is deliberately thin: chrome + an empty mount
/// carrying the conv base; the ChatFirstTopic client module owns the intro, the
/// styling, and the ChatAddTopic widget (pre-filled "general") that POSTs
/// <base>/new and navigates to the created topic. `base` is "/chat/c/<pair>" or
/// "/channel/<name>"; the widget is base-shape-agnostic.
pub fn noTopicsPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, base: []const u8, title: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    try sendHtml(req, .ok, try noTopicsHtml(alloc, viewer, base, title));
}

/// noTopicsPage's bytes, for `viewer` (Roc's twin: roc-webbox chat/Pages.roc).
pub fn noTopicsHtml(alloc: Alloc, viewer: []const u8, base: []const u8, title: []const u8) ![]const u8 {
    var page = try chrome.page(alloc, "Chat", title, viewer, "chat");
    const b = &page.body;
    try b.print(alloc, "<div id=\"chat-first-topic\" data-conv-base=\"{s}\"></div>", .{try htmlEscape(alloc, base)});
    try b.appendSlice(alloc, try chrome.script(alloc, "chat_add_topic.js"));
    try b.appendSlice(alloc, try chrome.script(alloc, "chat_first_topic.js"));
    return page.bytes();
}

fn sendHtml(req: *Request, status: std.http.Status, bytes: []const u8) !void {
    try req.respond(bytes, .{ .status = status, .extra_headers = &.{http.html_ct} });
}

/// **A 404 THAT SAYS WHY** (metal-vmm QUEUE 156(j)): `what` names what is not
/// there, and `back` is where to go instead. A page, not a bare "not found".
pub fn notFoundPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, what: []const u8, back: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    try sendHtml(req, .not_found, try notFoundHtml(alloc, viewer, what, back));
}

/// notFoundPage's bytes, for `viewer`.
pub fn notFoundHtml(alloc: Alloc, viewer: []const u8, what: []const u8, back: []const u8) ![]const u8 {
    var page = try chrome.page(alloc, "Chat", "Not here", viewer, "chat");
    const b = &page.body;
    try b.print(alloc, "<p>{s}</p><p><a href=\"{s}\">Go back</a></p>", .{ try htmlEscape(alloc, what), try htmlEscape(alloc, back) });
    return page.bytes();
}

// ── the conversation page (boots the prod JS) ────────────────────────────────

pub fn conversationPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, topic: Topic, now: Now) !void {
    const conv = topic.conv;
    // Remember where this user is — the /chat/default resume pointer, keyed by
    // pair. Only convs that persist a cursor (DMs) do this; channels don't.
    if (conv.persistsCursor()) try chat_state.setLastViewedTopic(io, alloc, uid, conv.key, topic.sid);
    const viewer = try users.getUserName(io, alloc, uid);
    const sidebar_json = try sidebarJSON(alloc, try sidebarOf(io, alloc, uid, topic, now));
    try sendHtml(req, .ok, try conversationHtml(alloc, .{ .key = conv.key, .base = conv.base, .sid = topic.sid, .title = topic.title, .uid = uid, .viewer = viewer, .sidebar_json = sidebar_json }));
}

/// What the conversation page shows, read: the conversation's key and URL
/// base, the topic, its title, the viewer, and the sidebar's JSON.
pub const View = struct { key: []const u8, base: []const u8, sid: []const u8, title: []const u8, uid: []const u8, viewer: []const u8, sidebar_json: []const u8 };

/// conversationPage's bytes, from what it read (Roc's twin: chat/Pages.roc).
pub fn conversationHtml(alloc: Alloc, v: View) ![]const u8 {
    var page = try chrome.page(alloc, "Chat", v.title, v.viewer, "");
    // doctype + <head> + platform style + colors/theme scripts + top bar +
    // open .app-body-wrap. active="" so no nav link is bolded inside a conv.
    const b = &page.body;

    try b.appendSlice(alloc, chat_css);
    // data-me: the viewer's uid, so the client can tell its own reactions apart.
    // data-me-name: the viewer's name, so the client can tell its own messages
    // apart (a message names its author; the stream sends every viewer the
    // same frame, chat_frame.zig).
    // data-upload-*: the server's caps and accepted types, the client's only
    // copy (metal-vmm QUEUE 157(d)).
    try b.print(alloc, "<div id=\"chat-root\" data-conv=\"{s}\" data-conv-base=\"{s}\" data-session=\"{s}\" data-me=\"{s}\" data-me-name=\"{s}\" data-upload-image-max=\"{d}\" data-upload-video-max=\"{d}\" data-upload-accept=\"{s}\" data-search-min=\"{d}\">", .{
        try htmlEscape(alloc, v.key), try htmlEscape(alloc, v.base), try htmlEscape(alloc, v.sid), try htmlEscape(alloc, v.uid),         try htmlEscape(alloc, v.viewer),
        chat_upload.image_max,        chat_upload.video_max,         chat_upload.accept,           @import("search_tokens.zig").min_len,
    });
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div class=\"chat-layout\">");

    // left-rail mount + the inline sidebar payload (first paint, no round-trip).
    try b.appendSlice(alloc, "<div id=\"chat-left-sidebar\"></div>");
    try b.print(alloc, "<script type=\"application/json\" id=\"chat-sidebar-data\">{s}</script>", .{v.sidebar_json});

    try b.appendSlice(alloc, "<div id=\"chat-feed\"></div>");
    try b.appendSlice(alloc, "<div id=\"chat-right-sidebar\"></div></div>");

    // sibling bundles, in document order, then close #chat-root + the chrome.
    try b.appendSlice(alloc, "</div>");
    inline for (page_scripts) |name| try b.appendSlice(alloc, try chrome.script(alloc, name));
    return page.bytes();
}

/// Another member, as the sidebar lists them.
pub const Other = struct { id: []const u8, name: []const u8, online: bool };

/// What the sidebar shows, read: the viewer, the conversation (`dm` its kind
/// or a channel's), the topic, every other member, the viewer's channels,
/// their pins in this conversation, and its topics.
pub const Sidebar = struct {
    uid: []const u8,
    dm: bool,
    key: []const u8,
    base: []const u8,
    sid: []const u8,
    others: []const Other,
    channels: []const []const u8,
    pins: [][]const u8,
    topics: []const []const u8,
};

/// **THE SIDEBAR AS IT CROSSES TO THE ROC** (`Host.page!`, chat/Pages.roc
/// `decode_sidebar`): the viewer, "1" for a DM, the key, base and topic,
/// then each list counted: the others (id, name, "1" when online), the
/// channels, the pins, the topics.
pub fn sidebarFields(alloc: Alloc, sb: Sidebar) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(alloc, &.{ sb.uid, if (sb.dm) "1" else "0", sb.key, sb.base, sb.sid, try std.fmt.allocPrint(alloc, "{d}", .{sb.others.len}) });
    for (sb.others) |o| try out.appendSlice(alloc, &.{ o.id, o.name, if (o.online) "1" else "0" });
    for ([_][]const []const u8{ sb.channels, sb.pins, sb.topics }) |list| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{list.len}));
        try out.appendSlice(alloc, list);
    }
    return out.items;
}

/// The sidebar's data, read for `topic`.
pub fn sidebarOf(io: Io, alloc: Alloc, uid: []const u8, topic: Topic, now: Now) !Sidebar {
    const conv = topic.conv;
    var others: std.ArrayList(Other) = .empty;
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, uid)) continue;
        // online: the partner row's first-paint dot.
        try others.append(alloc, .{ .id = u.id, .name = u.name, .online = presence.isOnline(u.id, now) });
    }
    const channels = try chat_paths.listUserChannels(io, alloc, uid);
    // Topics split by pinned state: the conv's pins (conv-key form) intersect
    // the live topic list — stale ids drop out.
    const pins = try chat_state.pinnedTopics(io, alloc, uid, conv.key);
    const topics = try chat_paths.listTopics(io, alloc, conv.dir);
    return .{ .uid = uid, .dm = conv.meta.kind == .dm, .key = conv.key, .base = conv.base, .sid = topic.sid, .others = others.items, .channels = channels, .pins = pins, .topics = topics };
}

/// sidebarJSON is the inline left-rail payload: conversations = every other
/// authorized user (DM) + every channel the viewer is in; pinned_sessions and
/// topics = this conv's topics, pinned or not. The `</`→`<\/` pass is
/// script-tag safety for inline embedding. Roc's twin: chat/Pages.roc.
pub fn sidebarJSON(alloc: Alloc, sb: Sidebar) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, "{\"conversations\":[");

    var first = true;
    for (sb.others) |u| {
        if (!first) try b.append(alloc, ',');
        first = false;
        const pk = try chat_paths.chatPairKey(alloc, sb.uid, u.id);
        const active = sb.dm and std.mem.eql(u8, pk, sb.key);
        // Every string escaped, ids and URLs too: a name the store would
        // never take must still make JSON, not break the page's script.
        const id = try std.fmt.allocPrint(alloc, "uid:{s}", .{u.id});
        const url = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{pk});
        try b.print(alloc, "{{\"id\":{f},\"label\":{f},\"url\":{f},\"active\":{}", .{
            std.json.fmt(id, .{}), std.json.fmt(u.name, .{}), std.json.fmt(url, .{}), active,
        });
        // online (omitted when false).
        if (u.online) try b.appendSlice(alloc, ",\"online\":true");
        try b.append(alloc, '}');
    }
    for (sb.channels) |name| {
        if (!first) try b.append(alloc, ',');
        first = false;
        const active = !sb.dm and std.mem.eql(u8, name, sb.key);
        const label = try std.fmt.allocPrint(alloc, "# {s}", .{name});
        const id = try std.fmt.allocPrint(alloc, "ch:{s}", .{name});
        const url = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});
        try b.print(alloc, "{{\"id\":{f},\"label\":{f},\"url\":{f},\"active\":{}}}", .{
            std.json.fmt(id, .{}), std.json.fmt(label, .{}), std.json.fmt(url, .{}), active,
        });
    }

    try b.appendSlice(alloc, "],\"pinned_sessions\":[");
    first = true;
    for (sb.topics) |s| {
        if (!chat_state.isPinned(sb.pins, s)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        try emitTopicItem(&b, alloc, sb.base, s, sb.sid);
    }
    try b.appendSlice(alloc, "],\"topics\":[");
    first = true;
    for (sb.topics) |s| {
        if (chat_state.isPinned(sb.pins, s)) continue;
        if (!first) try b.append(alloc, ',');
        first = false;
        try emitTopicItem(&b, alloc, sb.base, s, sb.sid);
    }
    try b.appendSlice(alloc, "]}");

    return html.scriptSafe(alloc, b.items);
}

/// emitTopicItem appends one topic row (`{id,label,url,active}`) to the
/// sidebar JSON — shared by the pinned and unpinned passes.
fn emitTopicItem(b: *std.ArrayList(u8), alloc: Alloc, base: []const u8, s: []const u8, sid: []const u8) !void {
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
    try sendHtml(req, .ok, try noConversationsHtml(alloc, viewer));
}

/// noConversationsPage's bytes, for `viewer`.
pub fn noConversationsHtml(alloc: Alloc, viewer: []const u8) ![]const u8 {
    var page = try chrome.page(alloc, "Chat", "Chat", viewer, "chat");
    const b = &page.body;
    try b.appendSlice(alloc, "<p>You do not have any conversations.</p>");
    return page.bytes();
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
