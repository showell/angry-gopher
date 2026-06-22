//! images: /chat/images — the per-user image transcript, handler half.
//! Reads the viewer's images.md (populated by the appendMessage cross-page
//! fanout in chat_store), keeps the most-recent 20 entries, and ships them as
//! inline JSON (#images-data) next to #images-mount — the same imagesSSEEvent
//! shape images.js uses for both first-paint and the live /chat/images/stream
//! upserts. The stream is a per-uid subscriber on the images bus (live-only; the
//! server-rendered page is the backlog), now fed for real by the fanout.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const images_store = @import("images_store.zig");
const chat = @import("chat.zig");
const chrome = @import("chrome.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// imagesPageLimit caps how many of the most-recent entries the page renders —
/// it's a "what got shared lately" feed and every entry is a full image, so the
/// tail keeps it light over a slow link.
const images_page_limit = 20;

/// handle dispatches /chat/images* — `rest` is the path after "/images" ("" or
/// "/stream").
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    if (rest.len == 0) return renderImagesPage(req, io, alloc, uid);
    if (std.mem.eql(u8, rest, "/stream")) {
        return chat.forwardUserStream(req, alloc, bus, try store.imagesBusKey(alloc, uid));
    }
    return http.notFound(req);
}

fn renderImagesPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    var entries = try images_store.readImagesForUser(io, alloc, uid);
    // Oldest-first on disk; keep only the most-recent imagesPageLimit (the tail).
    if (entries.len > images_page_limit) entries = entries[entries.len - images_page_limit ..];

    var b: std.ArrayList(u8) = .empty;
    try chrome.begin(&b, alloc, "Images", "Images", viewer, "images");
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"images-mount\"></div>");
    try emitImagesData(&b, alloc, entries);
    try b.print(alloc, "<script src=\"/chat/styles.js?v={s}\"></script>" ++
        "<script src=\"/chat/chat_image_popup.js?v={s}\"></script>" ++
        "<script src=\"/chat/images.js?v={s}\"></script>" ++
        "<script src=\"/chat/notify.js?v={s}\"></script>", .{ chrome.asset_v, chrome.asset_v, chrome.asset_v, chrome.asset_v });
    try chrome.end(&b, alloc);

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// emitImagesData ships the initial transcript as inline JSON. The `</`→`<\/`
/// pass prevents the JSON from closing the surrounding <script>. Per-entry
/// source_url is rebuilt from the entry's conv.
fn emitImagesData(b: *std.ArrayList(u8), alloc: Alloc, entries: []images_store.ImagesEntry) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (entries, 0..) |e, i| {
        if (i != 0) try j.append(alloc, ',');
        const base = try store.convKeyBaseURL(alloc, e.conv);
        const src = try images_store.imagesSourceURL(alloc, base, e.source_id);
        try images_store.encodeImagesEvent(&j, alloc, e, src);
    }
    try j.append(alloc, ']');
    const safe = try replaceSeq(alloc, j.items, "</", "<\\/");
    try b.appendSlice(alloc, "<script id=\"images-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

/// replaceSeq returns `input` with every `needle` replaced by `repl` (alloc-owned).
fn replaceSeq(alloc: Alloc, input: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, input, needle, repl);
    const out = try alloc.alloc(u8, n);
    _ = std.mem.replace(u8, input, needle, repl, out);
    return out;
}
