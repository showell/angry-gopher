//! docs: the three-pane authoring surface inside the chat subsystem.
//! Left = the per-user doc list, middle = a textarea
//! (debounced autosave → /chat/docs/save), right = a live render (debounced
//! POST → /chat/docs/render, reusing the SAME markdown port chat messages use,
//! so docs and messages render identically). All endpoints act on the
//! authenticated principal only — never a uid from the request — so each member
//! reads/writes/creates only their own docs.
//!
//! Routes (the landing, a doc's editor, its raw markdown and the list are the
//! Roc's: roc-webbox chat/main.roc `docs_read!` and chat/Docs.roc, metal-vmm
//! QUEUE 289):
//!   POST /chat/docs/new           create (title) → 303 to the new doc
//!   POST /chat/docs/save          overwrite a doc body (autosave) → 204
//!   POST /chat/docs/render        markdown → HTML (live preview)
//!   POST /chat/docs/post          append the doc to the default chat partner → JSON
//!   GET  /chat/docs.js            the client bundle (served by chat.serveAsset, public)

const std = @import("std");
const chat_fanout = @import("chat_fanout.zig");
const Now = @import("request_time.zig").Now;
const limits = @import("limits.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const users = @import("users.zig");
const docs_store = @import("docs_store.zig");
const markdown = @import("markdown.zig");
const edge = @import("webbox").edge;
const chat = @import("chat.zig");
const timefmt = @import("timefmt.zig");
const feed = @import("recent_feed.zig");
const reading_list = @import("reading_list.zig");
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// maxDocBytes caps a single doc body — generous (1 MiB) but
/// bounded so a runaway client can't fill the disk.
const max_doc_bytes = limits.body.doc;

/// handle dispatches /chat/docs* — `rest` is the path after "/docs" (keeps its
/// leading '/', empty for "/chat/docs"). The docs URL space is flat (one segment
/// after /docs/), so a nested slash is a 404.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8, now: Now) !void {
    // The landing, the list, a doc's raw markdown and its editor are the
    // Roc's (roc-webbox chat/main.roc `docs_read!`, metal-vmm QUEUE 289).
    const seg = if (rest.len > 0) rest[1..] else rest; // rest starts with '/'
    if (std.mem.eql(u8, seg, "new")) return docsNew(req, io, alloc, bus, uid, now);
    if (std.mem.eql(u8, seg, "save")) return docsSave(req, io, alloc, bus, uid, now);
    if (std.mem.eql(u8, seg, "render")) return docsRender(req, alloc);
    // `post` is the Roc's (roc-webbox chat/main.roc `post_doc!`, metal-vmm QUEUE 278).
    if (std.mem.eql(u8, seg, "save_to_reading_list")) return docsSaveToReadingList(req, io, alloc, bus, uid, now);
    @panic("docs: a read page reached the Zig; the Roc serves them (metal-vmm QUEUE 289)");
}

// ── write verbs (POST) ────────────────────────────────────────────────────────

/// docsNew creates a new empty doc and 303s to it. Title is required (else back
/// to /chat/docs).
fn docsNew(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.redirect(req, .literal("/chat/docs"));
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const title_raw = (try chat.formField(alloc, body, "title")) orelse "";
    const title = std.mem.trim(u8, title_raw, " \t\r\n");
    if (title.len == 0) return http.redirect(req, .literal("/chat/docs"));
    const slug = try docs_store.createUserDoc(io, alloc, uid, title);
    publishDocRecent(alloc, bus, uid, slug, now);
    return http.redirect(req, try http.Target.format(alloc, "/chat/docs/{s}", .{slug}));
}

/// docsSave overwrites an existing doc's body (autosave target) → 204. A POST for
/// an unknown slug is rejected (autosave must not spawn a doc from a stale URL).
fn docsSave(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const slug_raw = (try chat.formField(alloc, body, "slug")) orelse "";
    const slug = std.mem.trim(u8, slug_raw, " \t\r\n");
    if (!docs_store.validDocSlug(slug)) return req.respond("bad slug\n", .{ .status = .bad_request });
    // **A SAVE SAYS WHAT IT SAVES** (metal-vmm QUEUE 172): a request with no
    // body field is refused, never read as an empty doc that wipes the one
    // there (as 156(b) found for /send). An empty field is an emptied doc.
    const doc_body = (try chat.formField(alloc, body, "body")) orelse
        return req.respond("not saved: no body\n", .{ .status = .bad_request });
    // A doc that is gone (a stale tab's autosave) is a 404; any other failure
    // goes on to the host's log as the 500 it is.
    docs_store.writeUserDoc(io, alloc, uid, slug, doc_body) catch |e| switch (e) {
        error.DocDoesNotExist => return req.respond("no such doc\n", .{ .status = .not_found }),
        else => return e,
    };
    publishDocRecent(alloc, bus, uid, slug, now);
    return req.respond("", .{ .status = .no_content });
}

/// publishDocRecent pings the author's own recent feed when they create or save a
/// doc. Docs are per-user, so no fan-out — only the
/// author sees it. Best-effort.
fn publishDocRecent(alloc: Alloc, bus: *Bus, uid: []const u8, slug: []const u8, now: Now) void {
    const at = timefmt.formatRFC3339UTC(alloc, now.unixSecs()) catch return;
    const title = docs_store.titleFromSlug(alloc, slug) catch return;
    var j: std.ArrayList(u8) = .empty;
    // who is always "You": docs are per-user, only the author sees this row.
    feed.encodeDocEvent(&j, alloc, at, "You", slug, title) catch return;
    const key = chat_fanout.recentBusKey(alloc, uid) catch return;
    bus.publish(key, j.items);
}

/// docsRender renders posted markdown to HTML for the live-preview pane, reusing
/// the chat markdown port.
fn docsRender(req: *Request, alloc: Alloc) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const md = (try chat.formField(alloc, body, "body")) orelse "";
    // The live-preview fuzz path. markdown.render returns the visible
    // malformed_html placeholder for hostile input (the existing observable);
    // count it too so /version reflects preview probing, not just POST rejects.
    if (try markdown.hostileReason(alloc, md) != null) edge.count(.malformed_markdown);
    const rendered = try markdown.render(alloc, md);
    try req.respond(rendered, .{ .extra_headers = &.{http.html_ct} });
}

/// docsSaveToReadingList appends one saved chat message to the caller's
/// reading-list doc (creating it on first save) → 204. The client sends the
/// snapshot as-seen (body markdown, author, display date) plus the conv/sid/id
/// locating the source message, plus the annotation. Acts only on the
/// authenticated principal's own doc — uid is the session principal, never the
/// request. reading_list.save caps the doc size (DocTooLarge → 413 here; a
/// hammering client hits the bound, not unbounded growth).
fn docsSaveToReadingList(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const conv = std.mem.trim(u8, (try chat.formField(alloc, body, "conv")) orelse "", " \t\r\n");
    const sid = std.mem.trim(u8, (try chat.formField(alloc, body, "sid")) orelse "", " \t\r\n");
    const id = std.mem.trim(u8, (try chat.formField(alloc, body, "id")) orelse "", " \t\r\n");
    const from = (try chat.formField(alloc, body, "from")) orelse "";
    const at = (try chat.formField(alloc, body, "at")) orelse "";
    const msg_body = (try chat.formField(alloc, body, "body")) orelse "";
    const note = (try chat.formField(alloc, body, "note")) orelse "";
    if (conv.len == 0 or sid.len == 0 or id.len == 0 or msg_body.len == 0) {
        return req.respond("missing field\n", .{ .status = .bad_request });
    }
    // A reading list at its cap is the client's limit (413); any other
    // failure goes on to the host's log (metal-vmm QUEUE 172).
    reading_list.save(io, alloc, uid, .{ .conv = conv, .sid = sid, .id = id }, from, at, msg_body, note) catch |e| switch (e) {
        error.DocTooLarge => return req.respond("not saved: the reading list is full\n", .{ .status = .payload_too_large }),
        else => return e,
    };
    publishDocRecent(alloc, bus, uid, reading_list.reading_list_slug, now);
    return req.respond("", .{ .status = .no_content });
}

// ── post-to-chat helpers ───────
// ── docsCSS ────────────────
