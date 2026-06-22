//! chrome: the chat-subsystem page shell — the one shared chrome that wraps
//! every authenticated sub-nav page (Chat, Docs, Recent, Images, Code, Links,
//! Settings). Single owner for the head, the platform stylesheet, the top bar +
//! sub-nav, and the `.app-body-wrap` content column.
//!
//! The contract is PAIRED. `begin()` emits everything down to the open
//! `<div class="app-body-wrap">`; the page emits its body (closing any inner
//! wrappers it opened); `end()` closes app-body-wrap + body + html. No page
//! hand-writes `</body></html>` anymore — that open-here/close-there seam used to
//! drift per page (a mobile-break source). It lives here once now, which is also
//! the single place to land a responsive/mobile rule when we want one.

const std = @import("std");
const html = @import("html.zig");
const Alloc = std.mem.Allocator;

/// Asset version (cache-buster) for the chrome's <script> tags and the per-page
/// bundle URLs. The server has no build stamp, so a constant suffices — it only
/// namespaces the browser cache.
pub const asset_v = "zig";

/// begin emits the shared chrome into `b`: the doctype/head + the platform
/// stylesheet (its <title> = `tab_title`), colors.js (sync, palette pre-paint) +
/// chat_theme.js (deferred), the top bar (Home + `title` + the sub-nav with
/// `active` bolded + identity), and the open `.app-body-wrap`. Pair with end().
pub fn begin(b: *std.ArrayList(u8), alloc: Alloc, tab_title: []const u8, title: []const u8, viewer: []const u8, active: []const u8) !void {
    try b.appendSlice(alloc, page_head_a);
    try b.appendSlice(alloc, tab_title);
    try b.appendSlice(alloc, page_head_b);
    try b.print(alloc, head_scripts, .{ asset_v, asset_v, asset_v, asset_v });
    try b.print(alloc, chrome_top_a, .{try html.htmlEscape(alloc, title)});
    try navLinks(b, alloc, active);
    try b.print(alloc, chrome_top_b, .{try html.htmlEscape(alloc, viewer)});
    try b.appendSlice(alloc, "<div class=\"app-body-wrap\">");
}

/// end closes what begin() opened: the `.app-body-wrap` column, then </body> and
/// </html>. A page that opened inner wrappers inside .app-body-wrap closes those
/// itself first, then calls end() — so the body/html close lives in exactly one
/// place.
pub fn end(b: *std.ArrayList(u8), alloc: Alloc) !void {
    try b.appendSlice(alloc, "</div></body></html>");
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
    .{ .href = "/chat/links", .label = "Links", .key = "links" },
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
    \\.app-top { background: var(--cc-top-bar-bg, #f0ede4);
    \\           border-bottom: 1px solid var(--cc-top-bar-border, #c9bfa7);
    \\           padding: 8px 24px;
    \\           font-family: sans-serif; display: flex; justify-content: space-between;
    \\           align-items: baseline;
    \\           position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: var(--cc-accent, #000080); text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.app-top-user { font-size: 13px; color: var(--cc-body-muted-fg, #444); }
    \\.app-top-user a { color: var(--cc-accent, #000080); }
    \\.chat-top .chat-top-left { display: flex; align-items: baseline; gap: 14px;
    \\                           flex-wrap: wrap; min-width: 0; }
    \\.chat-top-home { color: var(--cc-accent, #000080); text-decoration: none; font-size: 13px; }
    \\.chat-top-home:hover { text-decoration: underline; }
    \\.chat-top-title { font-weight: bold; color: var(--cc-accent, #000080); }
    \\.chat-top-links { font-size: 13px; }
    \\.chat-top-links a { color: var(--cc-accent, #000080); text-decoration: none; }
    \\.chat-top-links a:hover { text-decoration: underline; }
    \\.chat-notify { font-size:13px; color:var(--cc-notify-fg, #1a5fb4); overflow:hidden; text-overflow:ellipsis;
    \\               white-space:nowrap; min-width:0; }
    \\.chat-notify a { color:inherit; }
    \\.chat-notify a:hover { text-decoration:underline; }
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
// links, client owns where they show). Four {s} = asset version.
const head_scripts =
    \\<script src="/chat/colors.js?v={s}"></script><script>ChatColors.install();</script><script src="/chat/viewport.js?v={s}"></script><script defer src="/chat/chat_theme.js?v={s}"></script><script defer src="/chat/chrome_drawer.js?v={s}"></script>
;

// chrome_top_{a,b}: chatChromeTop, split around the sub-nav span so navLinks can
// emit the links with `active` bolded. chrome_top_a takes the escaped title;
// chrome_top_b takes the escaped viewer name. No admin link (none ported).
const chrome_top_a =
    \\<header class="app-top chat-top"><div class="chat-top-left"><a class="chat-top-home" href="/">Home</a><span class="chat-top-title">{s}</span><span class="chat-top-links">
;
const chrome_top_b =
    \\</span></div><div class="app-top-user"><button id="chat-theme-toggle" type="button" title="Toggle theme" aria-label="Toggle theme" style="background:none;border:none;cursor:pointer;font-size:16px;padding:0 8px;vertical-align:middle">🌙</button> · <strong>{s}</strong> · <a href="/settings">Settings</a> · <a href="/learn">Learn</a> · <a href="/logout">Log out</a></div></header>
;
