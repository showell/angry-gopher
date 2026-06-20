//! docs: the three-pane authoring surface inside the chat subsystem — Go's
//! server/chat/docs.go. Left = the per-user doc list, middle = a textarea
//! (debounced autosave → /chat/docs/save), right = a live render (debounced
//! POST → /chat/docs/render, reusing the SAME markdown port chat messages use,
//! so docs and messages render identically). All endpoints act on the
//! authenticated principal only — never a uid from the request — so each member
//! reads/writes/creates only their own docs.
//!
//! Routes (mirror Go's mux, registry.go):
//!   GET  /chat/docs               editor, no doc selected (list + nudge)
//!   GET  /chat/docs/<slug>        editor focused on one doc
//!   GET  /chat/docs/<slug>.md     the raw markdown (the literal file; API clients)
//!   GET  /chat/docs/list          JSON {me, docs:[{slug,title}]} (API clients)
//!   POST /chat/docs/new           create (title) → 303 to the new doc
//!   POST /chat/docs/save          overwrite a doc body (autosave) → 204
//!   POST /chat/docs/render        markdown → HTML (live preview)
//!   POST /chat/docs/post          append the doc to the default chat partner → JSON
//!   GET  /chat/docs.js            the client bundle (served by chat.serveAsset, public)
//!
//! The page chrome (head + top bar + .app-body-wrap) is chat.writeChrome with
//! active="docs"; the rest of the layout/CSS is reproduced from Go's renderDocsPage.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const docs_store = @import("docs_store.zig");
const markdown = @import("markdown.zig");
const edge = @import("edge.zig");
const chat = @import("chat.zig");
const chat_state = @import("chat_state.zig");
const timefmt = @import("timefmt.zig");
const feed = @import("recent_feed.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// maxDocBytes caps a single doc body (Go's maxDocBytes) — generous (1 MiB) but
/// bounded so a runaway client can't fill the disk.
const max_doc_bytes = 1 << 20;

/// handle dispatches /chat/docs* — `rest` is the path after "/docs" (keeps its
/// leading '/', empty for "/chat/docs"). The docs URL space is flat (one segment
/// after /docs/), so a nested slash is a 404.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    if (rest.len == 0 or std.mem.eql(u8, rest, "/")) {
        return renderDocsEditor(req, io, alloc, uid, "");
    }
    const seg = rest[1..]; // rest starts with '/'
    if (std.mem.eql(u8, seg, "list")) return docsList(req, io, alloc, uid);
    if (std.mem.eql(u8, seg, "new")) return docsNew(req, io, alloc, bus, uid);
    if (std.mem.eql(u8, seg, "save")) return docsSave(req, io, alloc, bus, uid);
    if (std.mem.eql(u8, seg, "render")) return docsRender(req, alloc);
    if (std.mem.eql(u8, seg, "post")) return docsPost(req, io, alloc, bus, uid);

    if (std.mem.indexOfScalar(u8, seg, '/') != null) return http.notFound(req);
    if (std.mem.endsWith(u8, seg, ".md")) {
        return serveRawDoc(req, io, alloc, uid, seg[0 .. seg.len - ".md".len]);
    }
    return renderDocsEditor(req, io, alloc, uid, seg);
}

// ── editor page (browser) ─────────────────────────────────────────────────────

/// renderDocsEditor renders the three-pane editor for `slug` ("" = no doc
/// selected). An unknown/invalid slug drops back to the bare editor (303),
/// mirroring Go's renderDocsEditor.
fn renderDocsEditor(req: *Request, io: Io, alloc: Alloc, uid: []const u8, slug_raw: []const u8) !void {
    const list = try docs_store.listUserDocs(io, alloc, uid);
    const slug = std.mem.trim(u8, slug_raw, " \t\r\n");
    if (slug.len != 0 and (!docs_store.validDocSlug(slug) or !slugInList(list, slug))) {
        return http.redirect(req, "/chat/docs");
    }
    var body: []const u8 = "";
    if (slug.len != 0) body = try docs_store.readUserDoc(io, alloc, uid, slug);
    try renderDocsPage(req, io, alloc, uid, list, slug, body);
}

fn slugInList(list: []docs_store.DocSummary, slug: []const u8) bool {
    for (list) |d| if (std.mem.eql(u8, d.slug, slug)) return true;
    return false;
}

fn renderDocsPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, list: []docs_store.DocSummary, slug: []const u8, body: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);

    var b: std.ArrayList(u8) = .empty;
    try chat.writeChrome(&b, alloc, "Docs", "Docs", viewer, "docs");
    try b.appendSlice(alloc, docs_css);

    // Cross-session new-message strip + favicon alert, shared with chat via
    // notify.js. Empty (zero-height) until a ping arrives.
    try b.appendSlice(alloc, "<div class=\"docs-notify chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div class=\"docs-layout\">");

    // Left pane: doc list + "+ New" form.
    try b.appendSlice(alloc, "<aside class=\"docs-list\">");
    try b.appendSlice(alloc, "<form method=\"post\" action=\"/chat/docs/new\" class=\"docs-new\">" ++
        "<input type=\"text\" name=\"title\" placeholder=\"New doc title\" autocomplete=\"off\" maxlength=\"80\" required>" ++
        "<button type=\"submit\">+ New</button></form>");
    if (list.len == 0) {
        try b.appendSlice(alloc, "<p class=\"docs-empty muted\">No docs yet. Type a title above to create one.</p>");
    } else {
        try b.appendSlice(alloc, "<ul class=\"docs-items\">");
        for (list) |d| {
            const active = if (std.mem.eql(u8, d.slug, slug)) " active" else "";
            try b.print(alloc, "<li class=\"docs-item{s}\"><a href=\"/chat/docs/{s}\">{s}</a></li>", .{
                active, d.slug, try chat.htmlEscape(alloc, d.title),
            });
        }
        try b.appendSlice(alloc, "</ul>");
    }
    try b.appendSlice(alloc, "</aside>");

    // Middle pane: title + textarea (or a hint when no doc is selected).
    try b.appendSlice(alloc, "<section class=\"docs-edit\">");
    if (slug.len == 0) {
        if (list.len == 0) {
            try b.appendSlice(alloc, "<p class=\"muted docs-hint\">Create your first doc on the left to start writing.</p>");
        } else {
            try b.appendSlice(alloc, "<p class=\"muted docs-hint\">Pick a doc on the left, or create a new one.</p>");
        }
    } else {
        const title = try docs_store.titleFromSlug(alloc, slug);
        try b.print(alloc, "<div class=\"docs-title-row\"><span class=\"docs-title\">{s}</span>" ++
            "<button type=\"button\" id=\"docs-post-btn\" class=\"docs-post-btn\">Post to chat</button>" ++
            "<span class=\"docs-status\" id=\"docs-status\"></span></div>", .{try chat.htmlEscape(alloc, title)});
        try b.print(alloc, "<textarea id=\"docs-body\" data-slug=\"{s}\" spellcheck=\"true\">{s}</textarea>", .{
            try chat.htmlEscape(alloc, slug), try chat.htmlEscape(alloc, body),
        });
    }
    try b.appendSlice(alloc, "</section>");

    // Right pane: live preview (server-render the initial body so it isn't blank
    // on load, and a JS-disabled browser still gets a read view).
    try b.appendSlice(alloc, "<section class=\"docs-preview\" id=\"docs-preview\">");
    if (slug.len != 0) try b.appendSlice(alloc, try markdown.render(alloc, body));
    try b.appendSlice(alloc, "</section>");

    try b.appendSlice(alloc, "</div>"); // .docs-layout

    // "Doc sent to chat" confirmation modal + docs.js, only when a doc is open.
    if (slug.len != 0) {
        try b.appendSlice(alloc, "<dialog id=\"docs-posted-dialog\" class=\"docs-alert-dialog\">" ++
            "<p>Doc sent to chat.</p><button type=\"button\" id=\"docs-posted-ok\">OK</button></dialog>");
        try b.print(alloc, "<script src=\"/chat/docs.js?v={s}\"></script>", .{chat.asset_v});
    }
    // notify.js loads even on the docs landing (the favicon alert + #chat-notify
    // strip should work here too).
    try b.print(alloc, "<script src=\"/chat/notify.js?v={s}\"></script>", .{chat.asset_v});
    try b.appendSlice(alloc, "</div></body></html>"); // close .app-body-wrap (PageFooter)

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// ── raw + list (API clients) ──────────────────────────────────────────────────

/// serveRawDoc returns a doc's raw markdown body (text/markdown). Acts on the
/// authenticated principal only. Mirrors Go's serveRawDoc.
fn serveRawDoc(req: *Request, io: Io, alloc: Alloc, uid: []const u8, slug: []const u8) !void {
    const exists = docs_store.docExists(io, alloc, uid, slug) catch return http.notFound(req);
    if (!exists) return http.notFound(req);
    const body = try docs_store.readUserDoc(io, alloc, uid, slug);
    try req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/markdown; charset=utf-8" },
    } });
}

/// docsList serves GET /chat/docs/list: a JSON listing of the principal's docs
/// (slug + display title) for API-key clients. Mirrors Go's HandleDocsList.
fn docsList(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req);
    const list = try docs_store.listUserDocs(io, alloc, uid);

    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "{{\"me\":{f},\"docs\":[", .{std.json.fmt(uid, .{})});
    var first = true;
    for (list) |d| {
        if (!first) try b.append(alloc, ',');
        first = false;
        try b.print(alloc, "{{\"slug\":{f},\"title\":{f}}}", .{
            std.json.fmt(d.slug, .{}), std.json.fmt(d.title, .{}),
        });
    }
    try b.appendSlice(alloc, "]}");
    try req.respond(b.items, .{ .extra_headers = &.{http.json_ct} });
}

// ── write verbs (POST) ────────────────────────────────────────────────────────

/// docsNew creates a new empty doc and 303s to it. Title is required (else back
/// to /chat/docs). Mirrors Go's HandleDocsNew.
fn docsNew(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8) !void {
    if (req.head.method != .POST) return http.redirect(req, "/chat/docs");
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const title_raw = (try chat.formField(alloc, body, "title")) orelse "";
    const title = std.mem.trim(u8, title_raw, " \t\r\n");
    if (title.len == 0) return http.redirect(req, "/chat/docs");
    const slug = try docs_store.createUserDoc(io, alloc, uid, title);
    publishDocRecent(io, alloc, bus, uid, slug);
    return http.redirect(req, try std.fmt.allocPrint(alloc, "/chat/docs/{s}", .{slug}));
}

/// docsSave overwrites an existing doc's body (autosave target) → 204. A POST for
/// an unknown slug is rejected (autosave must not spawn a doc from a stale URL).
/// Mirrors Go's HandleDocsSave.
fn docsSave(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const slug_raw = (try chat.formField(alloc, body, "slug")) orelse "";
    const slug = std.mem.trim(u8, slug_raw, " \t\r\n");
    const doc_body = (try chat.formField(alloc, body, "body")) orelse "";
    if (!docs_store.validDocSlug(slug)) return req.respond("bad slug\n", .{ .status = .bad_request });
    docs_store.writeUserDoc(io, alloc, uid, slug, doc_body) catch
        return req.respond("save failed\n", .{ .status = .internal_server_error });
    publishDocRecent(io, alloc, bus, uid, slug);
    return req.respond("", .{ .status = .no_content });
}

/// publishDocRecent pings the author's own recent feed when they create or save a
/// doc (Go's PublishDocRecent). Docs are per-user, so no fan-out — only the
/// author sees it. Best-effort.
fn publishDocRecent(io: Io, alloc: Alloc, bus: *Bus, uid: []const u8, slug: []const u8) void {
    const at = timefmt.formatRFC3339UTC(alloc, nowUnix(io)) catch return;
    const title = docs_store.titleFromSlug(alloc, slug) catch return;
    var j: std.ArrayList(u8) = .empty;
    feed.encodeDocEvent(&j, alloc, at, slug, title) catch return;
    const key = store.recentBusKey(alloc, uid) catch return;
    bus.publish(key, j.items);
}

/// docsRender renders posted markdown to HTML for the live-preview pane, reusing
/// the chat markdown port. Mirrors Go's HandleDocsRender.
fn docsRender(req: *Request, alloc: Alloc) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const md = (try chat.formField(alloc, body, "body")) orelse "";
    // The live-preview fuzz path. markdown.render returns the visible
    // malformed_html placeholder for hostile input (the existing observable);
    // count it too so /version reflects preview probing, not just POST rejects.
    if (markdown.hostileReason(md) != null) edge.count(.malformed_markdown);
    const html = try markdown.render(alloc, md);
    try req.respond(html, .{ .extra_headers = &.{http.html_ct} });
}

/// docsPost appends the doc's current body as a chat message to the caller's
/// default partner and returns {conv, session, id} so the client can navigate to
/// the posted message. Mirrors Go's HandleDocsPost.
fn docsPost(req: *Request, io: Io, alloc: Alloc, bus: *Bus, uid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);
    const body = (try http.readLimitedBody(req, alloc, max_doc_bytes)) orelse return;
    const slug_raw = (try chat.formField(alloc, body, "slug")) orelse "";
    const slug = std.mem.trim(u8, slug_raw, " \t\r\n");
    if (!docs_store.validDocSlug(slug)) return req.respond("bad slug\n", .{ .status = .bad_request });

    const doc_body = try docs_store.readUserDoc(io, alloc, uid, slug);
    if (std.mem.trim(u8, doc_body, " \t\r\n").len == 0) {
        return req.respond("doc is empty\n", .{ .status = .bad_request });
    }
    // Don't broadcast hostile / over-formatted markdown to a chat partner.
    if (markdown.hostileReason(doc_body)) |_| {
        return edge.reject(req, .malformed_markdown, "not posted: too much markdown formatting; break the doc up\n");
    }

    const partner = defaultChatPartner(uid);
    if (!try validChatPartner(io, alloc, uid, partner)) {
        return req.respond("no default chat partner available\n", .{ .status = .bad_request });
    }
    const conv = try store.chatPairKey(alloc, uid, partner);
    const sid = try chat_state.resolveSessionForUser(io, alloc, uid, conv);

    const conv_dir = try store.dmConvDir(alloc, conv);
    const from_name = try users.getUserName(io, alloc, uid);
    const members = try alloc.alloc([]const u8, 2);
    members[0] = uid;
    members[1] = partner;
    const meta = store.ConvMeta{ .kind = .dm, .members = members };
    const msg = try store.appendMessage(io, alloc, bus, meta, conv_dir, conv, sid, from_name, uid, doc_body, "");
    users.touchUser(io, alloc, uid);

    const out = try std.fmt.allocPrint(alloc, "{{\"conv\":{f},\"session\":{f},\"id\":{f}}}", .{
        std.json.fmt(conv, .{}), std.json.fmt(sid, .{}), std.json.fmt(msg.id, .{}),
    });
    try req.respond(out, .{ .extra_headers = &.{http.json_ct} });
}

// ── post-to-chat helpers (port of chat.go bits HandleDocsPost relies on) ───────

/// defaultChatPartner picks the partner id for "post to chat": Steve (id 1) talks
/// to Apoorva (id 2); everyone else talks to Steve. Hard-wired, like Go's.
fn defaultChatPartner(uid: []const u8) []const u8 {
    if (std.mem.eql(u8, uid, "1")) return "2";
    return "1";
}

/// validChatPartner: another authorized principal, not yourself or empty.
fn validChatPartner(io: Io, alloc: Alloc, uid: []const u8, partner: []const u8) !bool {
    if (partner.len == 0 or std.mem.eql(u8, partner, uid)) return false;
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, partner)) return true;
    }
    return false;
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

// ── docsCSS (Go's docsCSS: the three-pane grid + editor chrome) ────────────────

const docs_css =
    \\<style>
    \\html, body { height:100%; }
    \\.app-body-wrap { margin:10px auto; padding:0 18px 10px; min-height:0;
    \\                 max-width:1400px; display:flex; flex-direction:column; flex:1; }
    \\.docs-notify:not(:empty) { margin-bottom:6px; }
    \\.docs-layout { display:grid; grid-template-columns:220px 1fr 1fr; gap:14px;
    \\               flex:1; min-height:0; }
    \\.docs-list { border:1px solid var(--cc-border); border-radius:8px; background:var(--cc-card-bg);
    \\             padding:10px; overflow-y:auto; min-height:0; display:flex;
    \\             flex-direction:column; gap:10px; }
    \\.docs-new { display:flex; gap:6px; }
    \\.docs-new input { flex:1; min-width:0; padding:5px 7px; font-size:13px;
    \\                  border:1px solid var(--cc-border); background:var(--cc-bg); color:var(--cc-fg);
    \\                  border-radius:4px; font-family:inherit; }
    \\.docs-new button { padding:5px 10px; font-size:13px; }
    \\.docs-items { list-style:none; padding:0; margin:0; }
    \\.docs-item { padding:0; margin:2px 0; }
    \\.docs-item a { display:block; padding:5px 8px; border-radius:4px; color:var(--cc-accent);
    \\               text-decoration:none; font-size:13px; }
    \\.docs-item a:hover { background:var(--cc-search-sel-bg); }
    \\.docs-item.active a { background:var(--cc-accent); color:var(--cc-bg); font-weight:bold; }
    \\.docs-empty { font-size:12px; margin:0; }
    \\.docs-edit { display:flex; flex-direction:column; min-width:0; min-height:0; gap:6px; }
    \\.docs-title-row { display:flex; align-items:baseline; justify-content:space-between; gap:8px; }
    \\.docs-title { font-size:15px; font-weight:bold; color:var(--cc-accent); overflow:hidden;
    \\              text-overflow:ellipsis; white-space:nowrap; flex:1; min-width:0; }
    \\.docs-post-btn { padding:4px 12px; font-size:12px; flex:none; }
    \\.docs-status { font-size:12px; color:var(--cc-muted-fg); flex:none; }
    \\.docs-status.saving { color:var(--cc-muted-fg); }
    \\.docs-status.saved  { color:var(--cc-saved-fg); }
    \\.docs-status.error  { color:var(--cc-error); }
    \\.docs-alert-dialog { max-width:90vw; border:1px solid var(--cc-dialog-border);
    \\                     background:var(--cc-bg); color:var(--cc-fg);
    \\                     border-radius:8px; padding:18px 20px; }
    \\.docs-alert-dialog::backdrop { background:var(--cc-backdrop); }
    \\.docs-alert-dialog p { margin:0 0 14px; }
    \\.docs-alert-dialog button { padding:5px 16px; }
    \\#docs-body { flex:1; min-height:0; width:100%; box-sizing:border-box;
    \\             font-family:ui-monospace,Menlo,Consolas,monospace; font-size:14px;
    \\             line-height:1.45; padding:10px;
    \\             border:1px solid var(--cc-border); background:var(--cc-bg); color:var(--cc-fg);
    \\             border-radius:6px; resize:none; }
    \\.docs-preview { border:1px solid var(--cc-border); border-radius:8px; background:var(--cc-card-bg);
    \\                padding:14px 18px; overflow-y:auto; min-width:0; min-height:0;
    \\                overflow-wrap:anywhere; }
    \\.docs-preview p:first-child { margin-top:0; }
    \\.docs-preview pre { background:var(--cc-code-bg); padding:8px; border-radius:4px;
    \\                    overflow-x:auto; }
    \\.docs-preview img { max-width:100%; border-radius:6px; }
    \\.docs-preview a.msg-ref { font-family:ui-monospace,Menlo,Consolas,monospace;
    \\                          font-size:0.9em; background:var(--cc-accent-soft-bg); color:var(--cc-accent);
    \\                          padding:0 4px; border-radius:3px; text-decoration:none;
    \\                          cursor:default; }
    \\.docs-hint { margin-top:30px; text-align:center; }
    \\@media (max-width: 900px) {
    \\  .docs-layout { grid-template-columns:1fr; grid-auto-rows:minmax(180px, auto); }
    \\}
    \\</style>
;
