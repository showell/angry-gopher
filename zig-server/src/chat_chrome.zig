//! chrome: the chat-subsystem page shell — the one shared chrome that wraps
//! every authenticated sub-nav page (Chat, Docs, Recent, Images, Code, Links,
//! Settings). Single owner for the head, the platform stylesheet, the top bar +
//! sub-nav, and the `.app-body-wrap` content column.
//!
//! **A PAGE IS OPENED AND SENT** (metal-vmm QUEUE 157(e)): `page()` emits
//! everything down to the open `<div class="app-body-wrap">` and answers a
//! `Page`; the page writes its body into `Page.body` (closing any inner
//! wrappers it opened); `Page.send` closes app-body-wrap + body + html and
//! responds. No page hand-writes `</body></html>`, and none calls a closing
//! half by hand: the pair was `begin()`/`end()`, kept by each page, and the
//! open-here/close-there seam used to drift per page (a mobile-break source).

const std = @import("std");
const html = @import("webbox").html;
const http = @import("webbox").http;
const top_bar = @import("top_bar.zig");
const Alloc = std.mem.Allocator;

pub const Asset = @import("chat_client").Bundle;

/// The chat's client scripts (the `chat-client` checkout's `chat_client`).
/// Served verbatim at /chat/<name> with a JS content type (chat.zig), named
/// by the pages by their bytes (`src`).
pub const assets = @import("chat_client").bundles;

/// **WHERE A CHAT PAGE NAMES ITS SCRIPT `name`**: `/chat/<name>?h=<hash of
/// its bytes>` (http.hashedSrc), which the browser keeps for good. A name
/// not in `assets` does not build.
pub fn src(alloc: Alloc, comptime name: []const u8) ![]const u8 {
    const body = comptime for (assets) |a| {
        if (std.mem.eql(u8, a.name, name)) break a.body;
    } else @compileError("no chat asset named " ++ name);
    return http.hashedSrc(alloc, "/chat/" ++ name, body);
}

/// `<script src="..."></script>` for `name`, by `src`.
pub fn script(alloc: Alloc, comptime name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "<script src=\"{s}\"></script>", .{try src(alloc, name)});
}

/// begin emits the shared chrome into `b`: the doctype/head + the platform
/// stylesheet (its <title> = `tab_title`), colors.js (sync, palette pre-paint) +
/// chat_theme.js (deferred), the top bar (Home + `title` + the sub-nav with
/// `active` bolded + identity), and the open `.app-body-wrap`. Pair with end().
fn begin(b: *std.ArrayList(u8), alloc: Alloc, tab_title: []const u8, title: []const u8, viewer: []const u8, active: []const u8) !void {
    try b.appendSlice(alloc, page_head_a);
    try b.appendSlice(alloc, tab_title);
    try b.appendSlice(alloc, page_head_b);
    try b.print(alloc, head_scripts, .{ try src(alloc, "colors.js"), try src(alloc, "viewport.js"), try src(alloc, "chat_theme.js"), try src(alloc, "chrome_drawer.js") });
    try b.print(alloc, chrome_top_a, .{try html.htmlEscape(alloc, title)});
    try navLinks(b, alloc, active);
    try b.print(alloc, chrome_top_b, .{try html.htmlEscape(alloc, viewer)});
    try b.appendSlice(alloc, "<div class=\"app-body-wrap\">");
}

/// end closes what begin() opened: the `.app-body-wrap` column, then </body> and
/// </html>. Only `Page.send` calls it.
fn end(b: *std.ArrayList(u8), alloc: Alloc) !void {
    try b.appendSlice(alloc, "</div></body></html>");
}

/// A chrome page, open: write the page's own body into `body`, then `send`.
pub const Page = struct {
    alloc: Alloc,
    body: std.ArrayList(u8),

    /// Closes the page and answers it, HTML, with `status`.
    pub fn send(self: *Page, req: *std.http.Server.Request, status: std.http.Status) !void {
        try end(&self.body, self.alloc);
        try req.respond(self.body.items, .{ .status = status, .extra_headers = &.{http.html_ct} });
    }
};

/// Opens a chrome page (see `begin` for what it emits).
pub fn page(alloc: Alloc, tab_title: []const u8, title: []const u8, viewer: []const u8, active: []const u8) !Page {
    var p: Page = .{ .alloc = alloc, .body = .empty };
    try begin(&p.body, alloc, tab_title, title, viewer, active);
    return p;
}

const NavItem = struct { href: []const u8, label: []const u8, key: []const u8 };

/// nav_items is the chat-subsystem sub-nav — the content surfaces. Settings is
/// deliberately NOT here: it's a rarely-touched utility, so it sits with Learn /
/// Log out in the identity group (chrome_top_b), which the drawer also mirrors.
/// The admin link is omitted (no admin flag is ported), matching active="".
const nav_items = [_]NavItem{
    .{ .href = "/chat", .label = "Chat", .key = "chat" },
    .{ .href = "/chat/docs", .label = "Docs", .key = "docs" },
    .{ .href = "/chat/recent", .label = "Recent", .key = "recent" },
    .{ .href = "/chat/images", .label = "Images", .key = "images" },
    .{ .href = "/chat/code", .label = "Code", .key = "code" },
};

/// navLinks emits the sub-nav span body, " · "-joined, with the link whose key
/// equals `active` rendered bold-without-href.
fn navLinks(b: *std.ArrayList(u8), alloc: Alloc, active: []const u8) !void {
    var first = true;
    for (nav_items) |it| {
        if (!first) try b.appendSlice(alloc, " · ");
        first = false;
        if (std.mem.eql(u8, it.key, active)) {
            try b.print(alloc, "<strong>{s}</strong>", .{it.label});
        } else {
            try b.print(alloc, "<a href=\"{s}\">{s}</a>", .{ it.href, it.label });
        }
    }
}

// ── templates ────────────────────────────────────────────────────────────────

// page_head_{a,b}: PageHeadAndStyle — doctype, <head>, the shared platform
// stylesheet (AppChromeCSS + base rules, incl. the default .app-body-wrap
// content column), and <body> open. Split around the <title> text so begin() can
// drop the per-page tab title in between without a format string (the CSS's
// literal `%`/`{` would break one).
const page_head_a =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>
;
const page_head_b =
    \\</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 0; padding: 0;
    \\       display: flex; flex-direction: column; min-height: 100vh; }
    \\.app-body-wrap { flex: 1; max-width: 820px; margin: 32px auto; padding: 0 24px 60px;
    \\                 width: 100%; box-sizing: border-box; }
    \\
++ top_bar.css ++
    \\
    \\h1 { color: var(--cc-accent, #000080); }
    \\a { color: var(--cc-accent, #000080); }
    \\.muted { color: var(--cc-muted-fg, #888); }
    \\</style>
    \\</head><body>
    \\
;

// head_scripts: colors.js (sync, palette pre-paint) + viewport.js (sync, sets
// the vp-narrow class pre-paint so responsive CSS keys off it without its own
// @media; the single breakpoint authority) + chat_theme.js (deferred toggle
// wiring) + chrome_drawer.js (deferred; reads the top-bar nav we render below
// and, when Viewport says narrow, re-presents it as a drawer — server ships the
// links, client owns where they show). Four {s}: each one's `src`.
const head_scripts =
    \\<script src="{s}"></script><script>ChatColors.install();</script><script src="{s}"></script><script defer src="{s}"></script><script defer src="{s}"></script>
;

// chrome_top_{a,b}: chatChromeTop, split around the sub-nav span so navLinks can
// emit the links with `active` bolded. chrome_top_a takes the escaped title;
// chrome_top_b takes the escaped viewer name. No admin link (none ported).
const chrome_top_a =
    \\<header class="app-top chat-top"><div class="chat-top-left"><a class="chat-top-home" href="/">Home</a><span class="chat-top-title">{s}</span><span class="chat-top-links">
;
const chrome_top_b =
    \\</span></div><div class="app-top-user"><button id="chat-theme-toggle" type="button" title="Toggle theme" aria-label="Toggle theme" style="background:none;border:none;cursor:pointer;font-size:16px;padding:0 8px;vertical-align:middle">🌙</button> · <strong>{s}</strong> · <a href="/settings">Settings</a> · <a href="/logout">Log out</a></div></header>
;
