//! code: /chat/code — the per-user code transcript, handler half.
//! Reads the viewer's code.md (populated by the appendMessage cross-page fanout),
//! and ships ALL entries (oldest-first; no page cap, unlike Images) as inline
//! JSON (#code-data) next to #code-mount — the same codeSSEEvent shape code.js
//! uses for both first-paint and the live /chat/code/stream upserts. The stream
//! is a per-uid subscriber on the code bus (live-only; the page is the backlog).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const code_store = @import("code_store.zig");
const images_store = @import("images_store.zig");
const chat = @import("chat.zig");
const chrome = @import("chrome.zig");
const html = @import("html.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// handle dispatches /chat/code* — `rest` is the path after "/code" ("" or
/// "/stream").
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    if (rest.len == 0) return renderCodePage(req, io, alloc, uid);
    if (std.mem.eql(u8, rest, "/stream")) {
        return chat.forwardUserStream(req, alloc, bus, try store.codeBusKey(alloc, uid));
    }
    return http.notFound(req);
}

fn renderCodePage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const entries = try code_store.readCodeForUser(io, alloc, uid);

    var b: std.ArrayList(u8) = .empty;
    try chrome.begin(&b, alloc, "Code", "Code", viewer, "code");
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"code-mount\"></div>");
    try emitCodeData(&b, alloc, entries);
    try b.print(alloc, "<script src=\"/chat/styles.js?v={s}\"></script>" ++
        "<script src=\"/chat/chat_code_popup.js?v={s}\"></script>" ++
        "<script src=\"/chat/code.js?v={s}\"></script>" ++
        "<script src=\"/chat/notify.js?v={s}\"></script>", .{ chrome.asset_v, chrome.asset_v, chrome.asset_v, chrome.asset_v });
    try chrome.end(&b, alloc);

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// emitCodeData ships the initial transcript as inline JSON. The `</`→`<\/` pass
/// prevents the JSON from closing the surrounding <script>. Per-entry source_url
/// is rebuilt from the entry's conv (shares images_store's helper).
fn emitCodeData(b: *std.ArrayList(u8), alloc: Alloc, entries: []code_store.CodeEntry) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (entries, 0..) |e, i| {
        if (i != 0) try j.append(alloc, ',');
        const base = try store.convKeyBaseURL(alloc, e.conv);
        const src = try images_store.imagesSourceURL(alloc, base, e.source_id);
        try code_store.encodeCodeEvent(&j, alloc, e, src);
    }
    try j.append(alloc, ']');
    const safe = try html.scriptSafe(alloc, j.items);
    try b.appendSlice(alloc, "<script id=\"code-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

