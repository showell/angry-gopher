//! comments: public, read-anyone blog-post comments. A comment thread is a chat
//! transcript that happens to be web-public — so it reuses chat_store's append +
//! on-disk format wholesale (decodeChatFile / appendMessage). The thread has NO
//! members, so chat_store's cross-page fanout (notify/Recent/Images/Code, all
//! keyed `for (members)`) self-disables: a comment never leaks into anyone's
//! private feeds, with zero special-casing on the kind.
//!
//! Stored at {chat_root}/blog-comments/<slug>/sessions/comments.md. blog.zig only
//! ever hands us a slug it has ENUMERATED (a real post), so there's no traversal
//! surface and no orphan threads.
//!
//! Two poster levels (the model from #General): a fully-logged-in member (or an
//! existing guest) comments as themselves; a fresh visitor types a name and is
//! minted a guest uid inline — the exact /login guest flow — so every comment is
//! attributed to a real uid (what makes reactive moderation tractable). A
//! member-reserved name is refused (no impersonation).
//!
//! Bodies are HOSTILE user content: they pass markdown.hostileReason at the door
//! and render through markdown.render (the 256-token-capped path), exactly like
//! chat /send — NEVER renderTrusted (that exemption is for server-owned posts).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const login = @import("login.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");
const html = @import("html.zig");
const chat = @import("chat.zig");
const Conv = @import("conv.zig").Conv;
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// One flat thread per post (no sub-topics in Phase 2), so the session id is fixed.
const sid = "comments";
const max_comment_bytes = 64 * 1024;

/// convFor builds the memberless Conv addressing `slug`'s comment thread. The key
/// is namespaced `blog:<slug>` so it can't collide with a DM pair key or a channel
/// name in the bus keyspace.
fn convFor(alloc: Alloc, slug: []const u8) !Conv {
    return .{
        .meta = .{ .kind = .blog_comment, .members = &[_][]const u8{} },
        .key = try std.fmt.allocPrint(alloc, "blog:{s}", .{slug}),
        .base = try std.fmt.allocPrint(alloc, "/blog/{s}", .{slug}),
        .dir = try store.blogCommentDir(alloc, slug),
    };
}

/// renderThread appends the comments section — the existing comments then the
/// post form — for `slug` onto `b`. `viewer_name` is "" for an anon visitor (who
/// gets a name field) or the poster's display name (who gets a "commenting as"
/// line). Read-only: it decodes the backlog directly, never opening a live stream.
pub fn renderThread(b: *std.ArrayList(u8), io: Io, alloc: Alloc, slug: []const u8, viewer_name: []const u8) !void {
    const conv = try convFor(alloc, slug);
    const raw = (try store.rawSession(io, alloc, conv.dir, sid)) orelse "";
    const msgs = try store.decodeChatFile(alloc, raw);

    try b.appendSlice(alloc, "<section id=\"comments\" class=\"comments\"><h2>");
    if (msgs.len == 0) {
        try b.appendSlice(alloc, "Comments</h2><p class=\"muted\">No comments yet. Be the first.</p>");
    } else {
        try b.print(alloc, "{d} comment{s}</h2>", .{ msgs.len, if (msgs.len == 1) "" else "s" });
        for (msgs) |m| {
            // id="c-<msg id>" so the plain-form post-redirect can land on the new
            // comment (#c-comments_N) instead of scrolling back to the article top.
            try b.print(alloc, "<div id=\"c-{s}\" class=\"comment\"><div class=\"comment-head\"><strong>", .{m.id});
            try b.appendSlice(alloc, try html.htmlEscape(alloc, m.from));
            try b.appendSlice(alloc, "</strong><span class=\"comment-date\">");
            try b.appendSlice(alloc, try html.htmlEscape(alloc, m.date));
            try b.appendSlice(alloc, "</span></div><div class=\"comment-body\">");
            // HOSTILE content — the capped render, never renderTrusted.
            try b.appendSlice(alloc, try markdown.render(alloc, m.markdown));
            try b.appendSlice(alloc, "</div></div>");
        }
    }

    try b.print(alloc, "<form class=\"comment-form\" method=\"post\" action=\"/blog/{s}/comment\">", .{slug});
    if (viewer_name.len == 0) {
        try b.appendSlice(alloc, "<input class=\"comment-name\" name=\"name\" type=\"text\" maxlength=\"40\" placeholder=\"Your name\" autocomplete=\"off\">");
    } else {
        try b.print(alloc, "<p class=\"muted\">Commenting as <strong>{s}</strong>.</p>", .{try html.htmlEscape(alloc, viewer_name)});
    }
    try b.appendSlice(alloc, "<textarea class=\"comment-text\" name=\"comment\" rows=\"4\" placeholder=\"Add a comment\u{2026}\"></textarea>");
    try b.appendSlice(alloc, "<button type=\"submit\">Post comment</button></form>");
    // Rung B progressive enhancement (inert without JS — the form above still
    // posts and the server 303s to the new comment's anchor).
    try b.appendSlice(alloc, enhance_script);
    try b.appendSlice(alloc, "</section>");
}

/// enhance_script upgrades the plain form to post-without-reload: it intercepts
/// the submit, POSTs async (X-Comment-Async ⇒ the server answers 204 instead of a
/// 303), then re-fetches the page and swaps just the rendered `.comments` section
/// in place. The client ships NO markup — the server stays the single source of
/// the comment HTML (and the count + the name→"commenting as" flip come along for
/// free). Inline, like login.zig's standalone-page scripts; a network error falls
/// back to a real form submit. Snap scroll (no smooth), per house style.
const enhance_script =
    \\<script>
    \\(function(){
    \\  var form = document.querySelector('.comment-form');
    \\  if (!form || !window.fetch || !window.DOMParser) return;
    \\  function showErr(f, msg){
    \\    var e = f.querySelector('.comment-err');
    \\    if (!e){ e = document.createElement('p'); e.className = 'comment-err'; f.insertBefore(e, f.firstChild); }
    \\    e.textContent = msg;
    \\  }
    \\  function refresh(){
    \\    fetch(location.pathname).then(function(r){ return r.text(); }).then(function(html){
    \\      var doc = new DOMParser().parseFromString(html, 'text/html');
    \\      var fresh = doc.querySelector('.comments'), cur = document.querySelector('.comments');
    \\      if (!fresh || !cur){ location.reload(); return; }
    \\      cur.replaceWith(fresh);
    \\      bind(fresh.querySelector('.comment-form'));
    \\      var last = fresh.querySelector('.comment:last-of-type');
    \\      if (last) last.scrollIntoView({block:'center'});
    \\    }).catch(function(){ location.reload(); });
    \\  }
    \\  function bind(f){
    \\    if (!f) return;
    \\    f.addEventListener('submit', function(e){
    \\      e.preventDefault();
    \\      var btn = f.querySelector('button');
    \\      btn.disabled = true;
    \\      fetch(f.action, {
    \\        method: 'POST',
    \\        headers: {'Content-Type':'application/x-www-form-urlencoded','X-Comment-Async':'1'},
    \\        body: new URLSearchParams(new FormData(f)).toString()
    \\      }).then(function(r){
    \\        if (r.status === 204){ refresh(); return; }
    \\        return r.text().then(function(t){ showErr(f, t || 'Could not post your comment.'); btn.disabled = false; });
    \\      }).catch(function(){ f.submit(); });
    \\    });
    \\  }
    \\  bind(form);
    \\})();
    \\</script>
;

/// handlePost handles POST /blog/<slug>/comment. `slug` has already been validated
/// by blog.zig to name a real, enumerated post.
pub fn handlePost(req: *Request, io: Io, alloc: Alloc, bus: *Bus, slug: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    // Read header-derived state BEFORE the body (iterateHeaders asserts on
    // received_head, and the body read invalidates header strings).
    // X-Comment-Async marks the Rung-B fetch caller (⇒ 204, not a 303);
    // currentUser reads the identity cookies (it keeps gopher_uid owned).
    const is_async = if (try http.header(req, alloc, "x-comment-async")) |v| std.mem.eql(u8, v, "1") else false;
    const cur = try users.currentUser(io, alloc, req);

    const body = (try http.readLimitedBody(req, alloc, max_comment_bytes)) orelse return;
    const md_raw = (try chat.formField(alloc, body, "comment")) orelse "";
    const md = std.mem.trim(u8, md_raw, " \t\r\n");

    // Empty body is a no-op (and must NOT mint a guest for nothing).
    if (md.len == 0) {
        if (is_async) return req.respond("", .{ .status = .no_content });
        return redirectToThread(req, alloc, slug, "#comments", null);
    }
    // Refuse hostile / over-formatted markdown at the door, like chat /send.
    if (markdown.hostileReason(md)) |_| {
        return badComment(req, alloc, is_async, "Not posted: too much formatting — break it into smaller pieces.");
    }

    // Resolve the poster. An existing identity comments as itself; a fresh visitor
    // types a name and is minted a guest uid (the /login guest flow), refused if
    // the name is a member's.
    var from_id: []const u8 = cur.id;
    var from_name: []const u8 = cur.name;
    var set_cookie: ?[]const u8 = null;
    if (cur.id.len == 0) {
        const raw_name = (try chat.formField(alloc, body, "name")) orelse "";
        const vr = try users.validateUserName(alloc, raw_name);
        if (vr.err.len != 0) return badComment(req, alloc, is_async, vr.err);
        if (users.isNameReserved(io, alloc, vr.name)) {
            return badComment(req, alloc, is_async, "That name belongs to a registered member — pick another, or log in.");
        }
        from_id = try users.allocateUser(io, alloc, vr.name);
        from_name = vr.name;
        set_cookie = try login.uidCookie(alloc, from_id);
    }

    const conv = try convFor(alloc, slug);
    const msg = try store.appendMessage(io, alloc, bus, conv.meta, conv.dir, conv.key, sid, from_name, from_id, md, "");
    users.touchUser(io, alloc, from_id);

    // Async (Rung B): the client re-fetches + swaps the thread, so 204 is enough —
    // it just has to carry any just-minted guest cookie so the next post is "as X".
    if (is_async) {
        if (set_cookie) |c| {
            return req.respond("", .{ .status = .no_content, .extra_headers = &.{.{ .name = "set-cookie", .value = c }} });
        }
        return req.respond("", .{ .status = .no_content });
    }
    // Plain form: 303 to the NEW comment's anchor so the page lands there instead
    // of scrolling back to the article top.
    const anchor = try std.fmt.allocPrint(alloc, "#c-{s}", .{msg.id});
    return redirectToThread(req, alloc, slug, anchor, set_cookie);
}

/// redirectToThread 303s to the post page at `anchor` (e.g. "#c-comments_3"),
/// carrying a Set-Cookie when a guest identity was just minted so the visitor is
/// recognized on their next comment.
fn redirectToThread(req: *Request, alloc: Alloc, slug: []const u8, anchor: []const u8, cookie: ?[]const u8) !void {
    const loc = try std.fmt.allocPrint(alloc, "/blog/{s}{s}", .{ slug, anchor });
    var hs: std.ArrayList(std.http.Header) = .empty;
    try hs.append(alloc, .{ .name = "location", .value = loc });
    if (cookie) |c| try hs.append(alloc, .{ .name = "set-cookie", .value = c });
    try req.respond("", .{ .status = .see_other, .extra_headers = hs.items });
}

/// badComment fails loud with a 400. For the async caller it's a plain-text body
/// the script shows inline by the form; for a plain post it's a small page with a
/// back link — history.back() preserves the visitor's typed comment.
fn badComment(req: *Request, alloc: Alloc, is_async: bool, msg: []const u8) !void {
    if (is_async) {
        return req.respond(msg, .{ .status = .bad_request, .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        } });
    }
    const body = try std.fmt.allocPrint(alloc,
        \\<!doctype html><meta charset="utf-8">
        \\<body style="font-family:sans-serif;max-width:46rem;margin:48px auto;padding:0 24px;line-height:1.6">
        \\<p>{s}</p><p><a href="javascript:history.back()">← Back</a></p></body>
    , .{try html.htmlEscape(alloc, msg)});
    try req.respond(body, .{ .status = .bad_request, .extra_headers = &.{http.html_ct} });
}
