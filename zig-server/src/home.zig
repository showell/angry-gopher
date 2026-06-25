//! home: the site root "/" — the Lyn Rummy launch pad (Game / Puzzles / Driving
//! tiles). Public: anon visitors get the same marketing surface; the tiles route
//! through the login flow on click.
//!
//! This is the only surface on the GENERIC app chrome (the shared stylesheet +
//! the "Lyn Rummy · Chat" top bar + the "Playing as X / Log in" identity area);
//! the chat subsystem renders its own chat-flavored chrome in chat.zig. Kept as
//! string literals, like chat's chrome.
//!
//! `/version` lives here too: a tiny JSON build-identity probe, the smallest
//! observable surface, so it doubles as the redeploy smoke signal — bump
//! `version` to confirm a fresh binary is actually serving.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const http = @import("http.zig");
const edge = @import("edge.zig");
const users = @import("users.zig");
const chat = @import("chat.zig");
const html = @import("html.zig");
const mem_meter = @import("mem_meter.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// version is the build identity reported at /version. Bump it to make a
/// redeploy observable (the "minor observable change" smoke test).
pub const version = "0.1-zig";

/// handleHome serves "/" exactly; any other path that falls through here 404s.
/// `uid` is the resolved viewer ("" for anon).
pub fn handleHome(req: *Request, io: Io, alloc: Alloc, uid: []const u8, path: []const u8) !void {
    if (!std.mem.eql(u8, path, "/")) return http.notFound(req);

    const name = if (uid.len == 0) "" else try users.getUserName(io, alloc, uid);
    // Show the Admin link exactly when /admin is reachable: that gate keys on
    // uid "1" (see admin.zig), so this does too — link and gate stay honest.
    const is_admin = std.mem.eql(u8, uid, "1");

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, head_style);
    try writeTopBar(&b, alloc, name, is_admin);
    try b.appendSlice(alloc, body_html);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// handleVersion serves the JSON build-identity probe. `commit` is the git
/// short-hash baked in at build time (ops/deploy passes -Dcommit=...); it reads
/// "dev" for local builds. Together with `version` it pins exactly which build
/// is serving — the watchdog surfaces both in watchdog-status.txt.
pub fn handleVersion(req: *Request, alloc: Alloc) !void {
    // `rejects` is the edge-policy observable: a counter per reject kind (see
    // edge.zig). The watchdog polls /version, so a climbing counter surfaces in
    // watchdog-status.txt without any extra plumbing.
    const rejects = try edge.countsJSON(alloc);
    // `mem` is the live-byte meter (mem_meter.zig). Folding it into /version means
    // the watchdog — which already polls /version — surfaces it with no extra
    // plumbing; /debug/mem is the same numbers on a focused endpoint for the harness.
    const mem = try mem_meter.snapshotJSON(alloc);
    const body = try std.fmt.allocPrint(alloc,
        \\{{"result":"success","version":"{s}","commit":"{s}","rejects":{s},"mem":{s}}}
    , .{ version, build_options.commit, rejects, mem });
    try req.respond(body, .{ .extra_headers = &.{http.json_ct} });
}

/// handleDebugMem serves the live-byte meter as focused JSON — the endpoint the
/// stress harness polls between request bursts to watch for leaks (slope, not
/// level). Same numbers /version embeds; this is the tight-loop surface.
pub fn handleDebugMem(req: *Request, alloc: Alloc) !void {
    const body = try mem_meter.snapshotJSON(alloc);
    try req.respond(body, .{ .extra_headers = &.{http.json_ct} });
}

/// writeTopBar emits the generic app top bar. Anon visitors get a "Log in" link;
/// named visitors get "Playing as X [· Admin] · Log out" (name html-escaped).
fn writeTopBar(b: *std.ArrayList(u8), alloc: Alloc, name: []const u8, is_admin: bool) !void {
    try b.appendSlice(alloc,
        "<header class=\"app-top\"><div class=\"app-top-home\">" ++
        "<a href=\"/\">Lyn Rummy</a> · <a href=\"/chat\">Chat</a> · <a href=\"/blog\">Blog</a></div>" ++
        "<div class=\"app-top-user\">");
    if (name.len == 0) {
        try b.appendSlice(alloc, "<a href=\"/login\">Log in</a>");
    } else {
        const esc = try html.htmlEscape(alloc, name);
        const admin_link = if (is_admin) " · <a href=\"/admin\">Admin</a>" else "";
        try b.print(alloc, "Playing as <strong>{s}</strong>{s} · <a href=\"/logout\">Log out</a>", .{ esc, admin_link });
    }
    try b.appendSlice(alloc, "</div></header>");
}

// head_style: the doctype, <head>, shared app stylesheet, and opening <body> —
// the chrome for the generic (non-chat) pages.
const head_style =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 0; padding: 0;
    \\       display: flex; flex-direction: column; min-height: 100vh; }
    \\.app-body-wrap { flex: 1; max-width: 820px; margin: 32px auto; padding: 0 24px 60px;
    \\                 width: 100%; box-sizing: border-box; }
    \\
    \\/* PRODUCT_DECISION: top bars in this binary are STICKY — universal rule.
    \\   position:sticky + top:0 + z-index:10 + opaque background so scrolled
    \\   content can't bleed through. Applies to Recent / Images / Docs / Code
    \\   / Settings / Learn / etc. On the chat conversation page the document
    \\   doesn't scroll (the feed scrolls internally), so sticky is a no-op
    \\   there. When a page builds its own top bar in JS rather than reusing
    \\   this stylesheet (e.g. learn/learn.js's buildTopBar), it MUST replicate
    \\   the sticky + opaque-background contract. Cross-ref in buildTopBar
    \\   names this file as the canonical exemplar. */
    \\/* PRODUCT_DECISION: every color is var(--cc-..., #hex). The fallback is
    \\   the original light-mode hex, so pages that don't load chat/colors.js
    \\   (home, settings, lynrummy, learn) keep the legacy palette untouched.
    \\   Pages that DO load colors.js (chat-subsystem) get the dark palette
    \\   when the user toggles. */
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
    \\
    \\h1 { color: var(--cc-accent, #000080); }
    \\h2 { color: var(--cc-accent, #000080); margin-top: 24px; }
    \\a { color: var(--cc-accent, #000080); }
    \\nav { margin-bottom: 16px; font-size: 13px; }
    \\nav a { margin-right: 12px; }
    \\table { border-collapse: collapse; margin-top: 8px; width: 100%; }
    \\th { background: var(--cc-accent, #000080); color: white; padding: 6px 12px; text-align: left; }
    \\td { border-bottom: 1px solid var(--cc-border, #ccc); padding: 6px 12px; }
    \\tr:hover td { background: var(--cc-accent-soft-bg, #f0f0ff); }
    \\.muted { color: var(--cc-muted-fg, #888); }
    \\textarea { width: 100%; height: 60px; padding: 6px; box-sizing: border-box; margin: 8px 0; }
    \\button { background: #000080; color: white; border: none; padding: 8px 16px;
    \\         font-size: 14px; cursor: pointer; border-radius: 4px; }
    \\button:hover { background: #0000a0; }
    \\.back { margin-bottom: 16px; display: inline-block; }
    \\.flash { background: #c6f6c6; color: #1a7a3a; padding: 8px 12px; border-radius: 4px;
    \\         margin-bottom: 12px; animation: fadeout 3s forwards; }
    \\@keyframes fadeout { 0% { opacity: 1; } 70% { opacity: 1; } 100% { opacity: 0; } }
    \\.cards { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-top: 20px; }
    \\@media (max-width: 640px) { .cards { grid-template-columns: 1fr; } }
    \\.card { border: 1px solid #ccc; border-radius: 6px; padding: 20px; background: #fcfcf8; }
    \\.card h2 { margin: 0 0 8px; font-size: 22px; }
    \\.card h2 a { color: #000080; text-decoration: none; }
    \\.card h2 a:hover { text-decoration: underline; }
    \\.card p { color: #444; margin: 0 0 12px; font-size: 14px; }
    \\.card ul { list-style: none; padding: 0; margin: 0; }
    \\.card li { padding: 4px 0; }
    \\.card ul a { color: #000080; text-decoration: none; font-weight: bold; }
    \\.card ul a:hover { text-decoration: underline; }
    \\.card .muted { color: #888; font-weight: normal; }
    \\</style>
    \\</head><body>
    \\
;

// body_html: the title <h1>, subtitle, and the games hero tiles. Wholly static —
// no per-viewer variation below the top bar.
const body_html =
    \\<div class="app-body-wrap"><h1>Lyn Rummy</h1>
    \\<p style="color:#666;font-size:13px;margin-top:-8px;margin-bottom:12px">Jump into a game, browse the puzzles, or take a drive.</p>
    \\<style>
    \\.games-hero { margin:20px 0 28px; display:grid; grid-template-columns:repeat(3, 1fr); gap:20px; }
    \\@media (max-width: 900px) { .games-hero { grid-template-columns:1fr 1fr; } }
    \\@media (max-width: 600px) { .games-hero { grid-template-columns:1fr; } }
    \\.games-tile { border:1px solid #ccc; border-radius:8px; padding:22px; background:#fcfcf8;
    \\              display:flex; flex-direction:column; }
    \\.games-tile h2 { margin:0 0 6px; font-size:22px; color:#000080; }
    \\.games-tile p { color:#444; margin:0 0 16px; font-size:14px; line-height:1.5; }
    \\.games-tile .cta { margin-top:auto; }
    \\.play-btn { display:inline-block; background:#000080; color:white; padding:12px 28px;
    \\            border-radius:6px; text-decoration:none; font-weight:bold; font-size:16px; }
    \\.play-btn:hover { background:#0000a0; }
    \\</style>
    \\<div class="games-hero">
    \\  <div class="games-tile">
    \\    <h2>Game</h2>
    \\    <p>Two-player rummy with a real referee. Drag cards from your hand to the board, build runs and sets, hit Complete Turn when you're happy with your play.</p>
    \\    <div class="cta">
    \\      <a class="play-btn" href="/game">Play a game →</a>
    \\    </div>
    \\  </div>
    \\  <div class="games-tile">
    \\    <h2>Puzzles</h2>
    \\    <p>A single board, mid-game. Drag stacks to merge or split your way to a clean meld layout. Solo, no opponent — undo is free, and Replay walks back through your moves.</p>
    \\    <div class="cta">
    \\      <a class="play-btn" href="/puzzles">Solve puzzles →</a>
    \\    </div>
    \\  </div>
    \\  <div class="games-tile">
    \\    <h2>Driving</h2>
    \\    <p>A first-person motorcycle ride down a winding road. Steer through the turns with the arrow keys, or hit SPACE and let it drive itself. No goal, no clock — just the road.</p>
    \\    <div class="cta">
    \\      <a class="play-btn" href="/driving">Take a drive →</a>
    \\    </div>
    \\  </div>
    \\</div>
    \\<div class="card" style="margin-top:8px">
    \\  <h2><a href="/blog">Blog</a></h2>
    \\  <p>Notes from building this site — a single zig binary, written with Claude. Read along.</p>
    \\  <ul><li><a href="/blog">Read the blog →</a></li></ul>
    \\</div>
    \\</div></body></html>
;
