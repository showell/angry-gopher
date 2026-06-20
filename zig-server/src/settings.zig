//! settings: the member settings page. Today
//! one section — the bot API key. Self-service is safe because every action uses
//! the resolved identity (never a request-supplied id), so a member can only
//! manage their OWN key. Go gates these routes NEED_PASSWORD (members only); the
//! port mirrors that — an agent (no password) gets a 404.
//!
//!   GET  /settings          the settings page (?show=1 reveals the key,
//!                           ?keyrevoked=1 flashes the revoke confirmation)
//!   POST /settings/apikey   generate (or revoke=1) the caller's key

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const users = @import("users.zig");
const chat = @import("chat.zig");
const presence = @import("presence.zig");
const Bus = @import("bus.zig").Bus;

const Request = std.http.Server.Request;

/// handle dispatches /settings* — `sub` is the path after "/settings" ("" or
/// "/apikey"). Members only; presence is marked like Go's WithPresence.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0) return http.redirect(req, "/login");
    if (!users.isMember(io, alloc, uid)) return http.notFound(req); // NEED_PASSWORD
    presence.markActiveAndBroadcast(io, alloc, bus, uid);

    if (sub.len == 0) return renderSettings(req, io, alloc, uid);
    if (std.mem.eql(u8, sub, "/apikey")) return handleAPIKey(req, io, alloc, uid);
    return http.notFound(req);
}

/// handleAPIKey generates or revokes the caller's key (POST), acting only on the
/// resolved identity. GET falls back to the settings page.
fn handleAPIKey(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    if (req.head.method != .POST) return http.redirect(req, "/settings");
    const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
    const revoke = (try chat.formField(alloc, body, "revoke")) orelse "";
    if (std.mem.eql(u8, revoke, "1")) {
        users.clearUserAPIKey(io, alloc, uid);
        return http.redirect(req, "/settings?keyrevoked=1");
    }
    const key = try users.setUserAPIKey(io, alloc, uid);
    return renderKeyShown(req, io, alloc, uid, key, "/settings", "Settings");
}

fn renderSettings(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    var b: std.ArrayList(u8) = .empty;
    try chat.writeChrome(&b, alloc, "Settings", "Settings", viewer, "settings");

    if (queryFlag(req, "keyrevoked")) {
        try b.appendSlice(alloc, "<p class=\"flash\">Your API key was revoked.</p>");
    }

    try b.appendSlice(alloc, intro_html);

    if (!users.userHasAPIKey(io, alloc, uid)) {
        try b.appendSlice(alloc, "<p>You don't have an API key yet.</p>\n" ++
            "<form method=\"post\" action=\"/settings/apikey\" style=\"display:inline\"><button type=\"submit\">Generate key</button></form>");
        try b.appendSlice(alloc, "</div></body></html>");
        return req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
    }

    // Has a key. Reveal it on ?show=1; otherwise just the buttons.
    if (queryFlag(req, "show")) {
        if (try users.getUserAPIKey(io, alloc, uid)) |key| {
            try b.print(alloc, "<p>Your API key (copy it somewhere safe):</p>\n<code style=\"" ++ key_code_style ++ "\">{s}</code>", .{try chat.htmlEscape(alloc, key)});
        } else {
            try b.appendSlice(alloc, "<p class=\"muted\">This key predates the show feature — regenerate it to see the value.</p>");
        }
    } else {
        try b.appendSlice(alloc, "<p>You have an API key.</p>");
    }
    try b.appendSlice(alloc, key_buttons_html);
    try b.appendSlice(alloc, "</div></body></html>");
    return req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// renderKeyShown displays a freshly generated key once.
/// A standalone page (not chat chrome); the back link points at whichever surface
/// generated it (member /settings or the /admin panel). Shared with admin.zig.
pub fn renderKeyShown(req: *Request, io: Io, alloc: Alloc, uid: []const u8, key: []const u8, back_url: []const u8, back_label: []const u8) !void {
    const name = try chat.htmlEscape(alloc, try users.getUserName(io, alloc, uid));
    const safe_key = try chat.htmlEscape(alloc, key);
    const url = try chat.htmlEscape(alloc, back_url);
    const label = try chat.htmlEscape(alloc, back_label);
    const page = try std.fmt.allocPrint(alloc, key_shown_template, .{ url, label, name, safe_key });
    return req.respond(page, .{ .extra_headers = &.{http.html_ct} });
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// queryFlag reports whether the `?name=1` flag is present in the request target.
fn queryFlag(req: *Request, name: []const u8) bool {
    const v = queryValue(req.head.target, name) orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// queryValue pulls one (un-decoded) query parameter from a raw request target.
fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

// ── verbatim Go markup (settings.go / apikey_view.go) ─────────────────────────

const intro_html =
    \\<h2>API key</h2>
    \\<p class="muted">An API key lets a bot act as you through the chat API — read your
    \\conversations <strong>and send on your behalf</strong>. It can't reach admin, but otherwise
    \\treat it like your password. Hand it to the bot via the <code>GOPHER_API_KEY</code>
    \\environment variable, not in a prompt; revoke it here anytime.</p>
;

const key_code_style = "font-family:ui-monospace,Menlo,Consolas,monospace;font-size:15px;background:#f4f4ec;" ++
    "border:1px solid #ccc;padding:8px 12px;border-radius:4px;display:inline-block;" ++
    "user-select:all;word-break:break-all";

const key_buttons_html =
    \\<p>
    \\<form method="get" action="/settings" style="display:inline"><input type="hidden" name="show" value="1"><button type="submit">Show key</button></form>
    \\<form method="post" action="/settings/apikey" style="display:inline"><button type="submit">Regenerate key</button></form>
    \\<form method="post" action="/settings/apikey" style="display:inline"><input type="hidden" name="revoke" value="1"><button type="submit" style="background:#b00020">Revoke key</button></form>
    \\</p>
;

// key_shown_template — Go's RenderAPIKeyShown. Four {s} → back URL, back label,
// user name (heading), key. {{ / }} escape the CSS braces for std.fmt.
const key_shown_template =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body {{ font-family: sans-serif; margin: 40px; max-width: 640px; }}
    \\h1 {{ color: #000080; font-size: 22px; }}
    \\nav a {{ color: #000080; }}
    \\.warn {{ color: #b00020; }}
    \\.box {{ background: #f4f4ec; border: 1px solid #ccc; border-radius: 6px; padding: 16px 20px; }}
    \\code.key {{ font-family: ui-monospace,Menlo,Consolas,monospace; font-size: 15px;
    \\           background: #fff; border: 1px solid #ccc; padding: 8px 12px; border-radius: 4px;
    \\           display: block; user-select: all; word-break: break-all; }}
    \\.muted {{ color: #888; font-size: 13px; }}
    \\</style>
    \\</head><body>
    \\<nav><a href="{s}">← {s}</a></nav>
    \\<h1>API key for &ldquo;{s}&rdquo;</h1>
    \\<div class="box">
    \\<p class="warn"><strong>Copy this for the bot.</strong></p>
    \\<code class="key">{s}</code>
    \\<p class="muted">Acts as you (read + send), but not admin — treat it like your password.
    \\The bot sends it as <code>Authorization: Bearer &lt;key&gt;</code>; hand it over via the
    \\<code>GOPHER_API_KEY</code> env var, not in the prompt. Revoke anytime.</p>
    \\</div>
    \\</body></html>
;
