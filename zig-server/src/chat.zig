//! chat: a READ-ONLY transcript view — the first slice of the chat port. It
//! renders one real on-disk conversation (a DM topic or a channel topic) from
//! the LIVE chat tree Go writes (chat_store.chat_root), reusing the ported
//! identity (users.zig) and the ported markdown renderer (markdown.zig). There
//! is no send/stream path yet: posting still goes through the Go server, and we
//! read the bytes back here — both binaries over one filesystem (the dogfood).
//!
//! Routes mirror Go's URL space (server/chat/chat.go), the subset we serve today:
//!   GET /chat                          index: the conversations this user can see
//!   GET /chat/c/<conv>                 303 → its default topic
//!   GET /chat/c/<conv>/<sid>           rendered DM transcript (read-only)
//!   GET /chat/c/<conv>/<sid>/raw       the literal on-disk .md bytes
//!   GET /channel/<name>/<topic>        rendered channel transcript (read-only)
//!   GET /channel/<name>/<topic>/raw    the literal on-disk .md bytes
//!
//! Access mirrors Go: identity resolves first (no identity → /login); a DM gates
//! on chatKeyParticipant, a channel on .channel membership; a non-participant or
//! malformed id 404s without revealing whether the conversation exists.
//!
//! Message bodies render through markdown.render, the byte-for-byte port of Go's
//! RenderChatMarkdown (goldmark GFM + hard-wraps + the MSG_ linkifier) — so the
//! rendered text here matches what the prod chat page shows for the same body.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// handle dispatches /chat/* — `sub` keeps its leading '/' (empty for exactly
/// "/chat"). Mirrors Go's HandleChat + HandleChatConv + the conv/sid routes.
pub fn handle(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0) return http.redirect(req, "/login");

    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try indexPage(req, io, alloc, uid);
        return;
    }
    if (matchPrefix(sub, "/c/")) |rest| {
        try convRoute(req, io, alloc, uid, rest);
        return;
    }
    try http.notFound(req);
}

/// handleChannel dispatches /channel/* — `sub` is the path after "/channel"
/// (leading '/'). Mirrors Go's channel raw/topic handlers.
pub fn handleChannel(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0) return http.redirect(req, "/login");

    var segs = segments(sub);
    const name = segs.next() orelse return http.notFound(req);
    if (!store.validChannelName(name)) return http.notFound(req);

    // Membership gate: an opaque 404 for non-members / non-existent channels.
    const members = (try store.channelMembers(io, alloc, name)) orelse return http.notFound(req);
    if (!store.hasMember(members, uid)) return http.notFound(req);

    const dir = try store.channelConvDir(alloc, name);
    const heading = try std.fmt.allocPrint(alloc, "#{s}", .{name});
    const base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});

    const topic = segs.next() orelse {
        // /channel/<name> → default topic.
        const def = try store.defaultSession(io, alloc, dir);
        if (def.len == 0) return http.notFound(req);
        const loc = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, def });
        return http.redirect(req, loc);
    };
    if (!store.validSessionID(topic)) return http.notFound(req);

    const tail = segs.next();
    if (tail) |t| {
        if (segs.next() != null or !std.mem.eql(u8, t, "raw")) return http.notFound(req);
        try rawTranscript(req, io, alloc, dir, topic);
        return;
    }
    try renderTranscript(req, io, alloc, dir, topic, heading, base);
}

/// convRoute handles /chat/c/<conv>[/<sid>[/raw]]. `rest` is the path after
/// "/c/". Mirrors Go's HandleChatConv + the conv/sid routes.
fn convRoute(req: *Request, io: Io, alloc: Alloc, uid: []const u8, rest: []const u8) !void {
    var segs = segments(rest);
    const conv = segs.next() orelse return http.notFound(req);

    // Participant gate: opaque 404 for non-participants / malformed keys.
    if (!try store.chatKeyParticipant(alloc, conv, uid)) return http.notFound(req);

    const dir = try store.dmConvDir(alloc, conv);
    const partner = try partnerName(io, alloc, conv, uid);
    const base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv});

    const sid = segs.next() orelse {
        // /chat/c/<conv> → default topic.
        const def = try store.defaultSession(io, alloc, dir);
        if (def.len == 0) return http.notFound(req);
        const loc = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, def });
        return http.redirect(req, loc);
    };
    if (!store.validSessionID(sid)) return http.notFound(req);

    const tail = segs.next();
    if (tail) |t| {
        if (segs.next() != null or !std.mem.eql(u8, t, "raw")) return http.notFound(req);
        try rawTranscript(req, io, alloc, dir, sid);
        return;
    }
    try renderTranscript(req, io, alloc, dir, sid, partner, base);
}

// ── transcript views ─────────────────────────────────────────────────────────

/// rawTranscript serves the literal on-disk .md bytes (text/plain, nosniff) —
/// the byte-for-byte parity check against Go's serveRawTranscript.
fn rawTranscript(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    const data = (try store.rawSession(io, alloc, conv_dir, sid)) orelse return http.notFound(req);
    try req.respond(data, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

/// renderTranscript decodes the session file and renders each message (header +
/// markdown→HTML body). `heading` is the conversation title (partner name or
/// "#channel"); `base` is its URL base (for the topic switcher + raw link).
fn renderTranscript(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, heading: []const u8, base: []const u8) !void {
    const raw = (try store.rawSession(io, alloc, conv_dir, sid)) orelse return http.notFound(req);
    const msgs = try store.decodeChatFile(alloc, raw);

    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, page_head, .{
        try htmlEscape(alloc, heading),
        try htmlEscape(alloc, sid),
        try htmlEscape(alloc, heading),
        try htmlEscape(alloc, sid),
        base,
        sid,
    });

    // Topic switcher: the other sessions in this conversation.
    const sessions = try store.listSessions(io, alloc, conv_dir);
    if (sessions.len > 1) {
        try b.appendSlice(alloc, "<nav class=\"topics\">topics: ");
        for (sessions) |s| {
            if (std.mem.eql(u8, s, sid)) {
                try b.print(alloc, "<strong>{s}</strong> ", .{try htmlEscape(alloc, s)});
            } else {
                try b.print(alloc, "<a href=\"{s}/{s}\">{s}</a> ", .{ base, s, try htmlEscape(alloc, s) });
            }
        }
        try b.appendSlice(alloc, "</nav>");
    }

    if (msgs.len == 0) {
        try b.appendSlice(alloc, "<p class=\"muted\">No messages yet.</p>");
    }
    for (msgs) |m| {
        const body_html = try markdown.render(alloc, m.markdown);
        try b.print(alloc, msg_block, .{
            try htmlEscape(alloc, m.id),
            try htmlEscape(alloc, m.from),
            try htmlEscape(alloc, m.date),
            body_html, // already safe HTML from the renderer
        });
    }
    try b.appendSlice(alloc, "</main></body></html>");
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// ── index ────────────────────────────────────────────────────────────────────

/// indexPage lists the conversations this user can see — the DM dirs they
/// participate in, and the channels they're a member of — each linking to its
/// default topic. A lightweight navigator for the read-only view (Go's /chat is
/// a picker; this is its read-only cousin).
fn indexPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, index_head);

    // DMs: top-level chat_root dirs shaped "<a>_<b>" with this uid a participant.
    try b.appendSlice(alloc, "<h2>Direct messages</h2><ul>");
    var any_dm = false;
    if (Io.Dir.cwd().openDir(io, store.chat_root, .{ .iterate = true })) |*dir_const| {
        var dir = dir_const.*;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!try store.chatKeyParticipant(alloc, entry.name, uid)) continue;
            const conv = try alloc.dupe(u8, entry.name);
            const partner = try partnerName(io, alloc, conv, uid);
            try b.print(alloc, "<li><a href=\"/chat/c/{s}\">{s}</a> <span class=\"muted\">({s})</span></li>", .{
                conv, try htmlEscape(alloc, partner), conv,
            });
            any_dm = true;
        }
    } else |_| {}
    if (!any_dm) try b.appendSlice(alloc, "<li class=\"muted\">none</li>");
    try b.appendSlice(alloc, "</ul>");

    // Channels: {chat_root}/channels/*.channel where this uid is a member.
    try b.appendSlice(alloc, "<h2>Channels</h2><ul>");
    var any_ch = false;
    const channels_dir = try std.fs.path.join(alloc, &.{ store.chat_root, "channels" });
    if (Io.Dir.cwd().openDir(io, channels_dir, .{ .iterate = true })) |*dir_const| {
        var dir = dir_const.*;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".channel")) continue;
            const name = entry.name[0 .. entry.name.len - ".channel".len];
            const members = (try store.channelMembers(io, alloc, name)) orelse continue;
            if (!store.hasMember(members, uid)) continue;
            try b.print(alloc, "<li><a href=\"/channel/{s}\">#{s}</a></li>", .{
                name, try htmlEscape(alloc, name),
            });
            any_ch = true;
        }
    } else |_| {}
    if (!any_ch) try b.appendSlice(alloc, "<li class=\"muted\">none</li>");
    try b.appendSlice(alloc, "</ul></main></body></html>");

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// ── small helpers ─────────────────────────────────────────────────────────────

/// partnerName resolves the OTHER uid's display name in DM key `conv` (relative
/// to `me`), falling back to the bare uid when there's no name on file.
fn partnerName(io: Io, alloc: Alloc, conv: []const u8, me: []const u8) ![]const u8 {
    const us = std.mem.indexOfScalar(u8, conv, '_') orelse return conv;
    const a = conv[0..us];
    const b = conv[us + 1 ..];
    const other = if (std.mem.eql(u8, a, me)) b else a;
    const name = try users.getUserName(io, alloc, other);
    return if (name.len == 0) other else name;
}

const SegIter = struct {
    rest: []const u8,
    fn next(self: *SegIter) ?[]const u8 {
        while (self.rest.len > 0 and self.rest[0] == '/') self.rest = self.rest[1..];
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, '/') orelse self.rest.len;
        const seg = self.rest[0..end];
        self.rest = self.rest[end..];
        return seg;
    }
};

/// segments iterates the non-empty '/'-separated path segments of `path`.
fn segments(path: []const u8) SegIter {
    return .{ .rest = path };
}

fn matchPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

/// htmlEscape mirrors Go's html.EscapeString (the same set game.zig escapes).
fn htmlEscape(alloc: Alloc, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "&'<>\"") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '\'' => try out.appendSlice(alloc, "&#39;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&#34;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

// ── templates ──────────────────────────────────────────────────────────────

// page_head slots: {s} title-heading, {s} title-sid (both in <title>); {s}
// heading, {s} sid (the h1/sub); {s} base, {s} sid (the raw link). `{` in the
// inline <style> is doubled for the format pass.
const page_head =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>{s} · {s}</title>
    \\<style>
    \\  body {{ font: 15px/1.6 system-ui, sans-serif; margin: 0; background: #f4f4ec; color: #222; }}
    \\  main {{ max-width: 52rem; margin: 0 auto; padding: 1.5rem 1.25rem 4rem; }}
    \\  h1 {{ font-size: 1.25rem; color: #000080; margin: 0 0 2px; }}
    \\  .sub {{ color: #666; font-size: 13px; margin: 0 0 1rem; }}
    \\  nav.top {{ background: #000080; color: #fff; padding: 8px 16px; font-size: 13px; }}
    \\  nav.top a {{ color: #fff; text-decoration: none; margin-right: 14px; }}
    \\  nav.topics {{ font-size: 13px; margin-bottom: 1rem; }}
    \\  nav.topics a {{ color: #000080; margin-right: .25rem; }}
    \\  .msg {{ background: #fff; border: 1px solid #e2e2d8; border-radius: 6px; padding: .5rem .85rem; margin: .6rem 0; }}
    \\  .meta {{ font-size: 12px; color: #888; margin-bottom: .35rem; }}
    \\  .meta .from {{ color: #000080; font-weight: 600; }}
    \\  .body :first-child {{ margin-top: 0; }}
    \\  .body :last-child {{ margin-bottom: 0; }}
    \\  .body pre {{ background: #f4f4ec; padding: .5rem; border-radius: 4px; overflow-x: auto; }}
    \\  .muted {{ color: #888; }}
    \\</style></head><body>
    \\<nav class="top"><a href="/">← Home</a><a href="/chat">Conversations</a></nav>
    \\<main>
    \\<h1>{s}</h1>
    \\<p class="sub">{s} · <a href="{s}/{s}/raw">raw</a></p>
;

// msg_block slots: {s} id, {s} from, {s} date, {s} rendered-HTML body.
const msg_block =
    \\<article class="msg" id="MSG_{s}">
    \\<div class="meta"><span class="from">{s}</span> · {s}</div>
    \\<div class="body">{s}</div>
    \\</article>
;

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
