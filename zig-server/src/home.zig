//! home: the site root "/" — the launch pad listing every app Steve & Claude
//! built (Seattle Delivery / Safari / Chat / Blog / Lyn Rummy / Puzzles). Public:
//! anon visitors get the same marketing surface; the rows route through the login
//! flow on click where a login is needed.
//!
//! The app rows are NOT hard-coded HTML: they're scripted in a tiny markdown-ish
//! DSL at `pages/home.txt` (read from disk at request time, alongside the resume —
//! both ride the `pages/` rsync), parsed here on the fly. One `## Title -> /href`
//! block per app, a `cta:` line for the button label, and a description paragraph.
//! `# Headline` sets the H1. Malformed/missing → a loud error page, never a silent
//! half-render. The resume footer line stays hard-coded below the parsed rows.
//!
//! This is the only surface on the GENERIC app chrome (the shared stylesheet +
//! the "Home · Chat · Blog" top bar + the "Playing as X / Log in" identity area);
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
    // The body (headline + app rows) is parsed from pages/home.txt on the fly. A
    // parse/read failure is loud, not papered over: show what broke, never a
    // silently-truncated page.
    if (renderHomeBody(io, alloc)) |body| {
        try b.appendSlice(alloc, body);
    } else |err| {
        try b.print(alloc,
            \\<div class="app-body-wrap"><h1>Home unavailable</h1>
            \\<p>pages/home.txt could not be rendered: <strong>{s}</strong>.</p></div></body></html>
        , .{@errorName(err)});
    }
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// An app row parsed from the DSL: a linked title, a CTA button label, a
/// description paragraph, and a low-key tech line (primary `lang` + an
/// interesting `tech` feature). `href` is both the title link and button target.
const App = struct { title: []const u8, href: []const u8, cta: []const u8, lang: []const u8, tech: []const u8, code: []const u8, essay: []const u8, image: []const u8, desc: []const u8 };

/// renderHomeBody reads pages/home.txt, parses the mini-DSL, and returns the inner
/// page body (the `.app-body-wrap` through `</body></html>`). Returns an error on
/// a missing file or any malformed block — the caller renders that loudly.
///
/// Grammar (markdown in spirit): a `# Headline` line sets the H1; each app is a
/// `## Title -> /href` block followed by `cta:`, `lang:`, `tech:`, and `code:`
/// lines and one or more description lines (joined with spaces, reflowed). An
/// optional `essay:` line adds a "Read more" link after the description. Blank lines
/// separate. Any stray text outside a block, a block missing any required field,
/// or no headline / no apps is `error.MalformedHome`.
fn renderHomeBody(io: Io, alloc: Alloc) ![]const u8 {
    const src = try Io.Dir.cwd().readFileAlloc(io, "pages/home.txt", alloc, .unlimited);

    var headline: []const u8 = "";
    var apps: std.ArrayList(App) = .empty;

    // The block currently being accumulated. `have` is false until the first `##`.
    var have = false;
    var c_title: []const u8 = "";
    var c_href: []const u8 = "";
    var c_cta: []const u8 = "";
    var c_lang: []const u8 = "";
    var c_tech: []const u8 = "";
    var c_code: []const u8 = "";
    var c_essay: []const u8 = "";
    var c_image: []const u8 = "";
    var c_desc: std.ArrayList(u8) = .empty;

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue; // blank lines only separate blocks
        if (std.mem.startsWith(u8, line, "## ")) {
            if (have) try pushApp(alloc, &apps, c_title, c_href, c_cta, c_lang, c_tech, c_code, c_essay, c_image, &c_desc);
            const rest = std.mem.trim(u8, line[3..], " ");
            const arrow = std.mem.indexOf(u8, rest, "->") orelse return error.MalformedHome;
            c_title = std.mem.trim(u8, rest[0..arrow], " ");
            c_href = std.mem.trim(u8, rest[arrow + 2 ..], " ");
            c_cta = "";
            c_lang = "";
            c_tech = "";
            c_code = "";
            c_essay = "";
            c_image = "";
            c_desc = .empty;
            have = true;
        } else if (std.mem.startsWith(u8, line, "# ")) {
            headline = std.mem.trim(u8, line[2..], " ");
        } else if (std.mem.startsWith(u8, line, "cta:")) {
            if (!have) return error.MalformedHome;
            c_cta = std.mem.trim(u8, line[4..], " ");
        } else if (std.mem.startsWith(u8, line, "lang:")) {
            if (!have) return error.MalformedHome;
            c_lang = std.mem.trim(u8, line[5..], " ");
        } else if (std.mem.startsWith(u8, line, "tech:")) {
            if (!have) return error.MalformedHome;
            c_tech = std.mem.trim(u8, line[5..], " ");
        } else if (std.mem.startsWith(u8, line, "code:")) {
            if (!have) return error.MalformedHome;
            c_code = std.mem.trim(u8, line[5..], " ");
        } else if (std.mem.startsWith(u8, line, "essay:")) {
            if (!have) return error.MalformedHome;
            c_essay = std.mem.trim(u8, line[6..], " ");
        } else if (std.mem.startsWith(u8, line, "image:")) {
            if (!have) return error.MalformedHome;
            c_image = std.mem.trim(u8, line[6..], " ");
        } else {
            if (!have) return error.MalformedHome; // stray prose outside any app block
            if (c_desc.items.len != 0) try c_desc.append(alloc, ' ');
            try c_desc.appendSlice(alloc, line);
        }
    }
    if (have) try pushApp(alloc, &apps, c_title, c_href, c_cta, c_lang, c_tech, c_code, c_essay, c_image, &c_desc);
    if (headline.len == 0 or apps.items.len == 0) return error.MalformedHome;

    // The headline renders as ordinary muted text, not a big H1 — the blue CTA
    // buttons are what should pop, not the page title.
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<div class=\"app-body-wrap home-wrap\"><p class=\"home-intro\">");
    try out.appendSlice(alloc, try html.htmlEscape(alloc, headline));
    try out.appendSlice(alloc, "</p>\n<div class=\"app-list\">\n");
    for (apps.items) |a| {
        // Optional "Read more" link to the app's essay. It shares a line with the
        // GitHub link (rendered in the template), so this is just the inner anchor.
        const more = if (a.essay.len > 0)
            try std.fmt.allocPrint(alloc, "<a href=\"{s}\">Read more →</a>", .{try html.htmlEscape(alloc, a.essay)})
        else
            "";
        // Optional app image (left of the text), itself a link to the app. 600x420
        // source → fixed 220x154 thumb (exact ratio, no distortion).
        const thumb = if (a.image.len > 0)
            try std.fmt.allocPrint(alloc, "<a class=\"app-thumb\" href=\"{s}\"><img src=\"{s}\" alt=\"{s}\" width=\"220\" height=\"154\" loading=\"lazy\"></a>", .{
                try html.htmlEscape(alloc, a.href),
                try html.htmlEscape(alloc, a.image),
                try html.htmlEscape(alloc, a.title),
            })
        else
            "";
        try out.print(alloc,
            \\<div class="app-row"><div class="app-row-top">{s}<div class="app-row-main"><h2><a href="{s}">{s}</a></h2><p>{s}</p><p class="app-more">{s}<a class="tech-code" href="{s}" target="_blank" rel="noopener">Code on GitHub ↗</a></p><p class="app-feat"><span class="tech-lang">{s}</span> {s}</p></div>
            \\<div class="cta"><a class="play-btn" href="{s}">{s}</a></div></div></div>
            \\
        , .{
            thumb,
            try html.htmlEscape(alloc, a.href),
            try html.htmlEscape(alloc, a.title),
            try html.htmlEscape(alloc, a.desc),
            more,
            try html.htmlEscape(alloc, a.code),
            try html.htmlEscape(alloc, a.lang),
            try html.htmlEscape(alloc, a.tech),
            try html.htmlEscape(alloc, a.href),
            try html.htmlEscape(alloc, a.cta),
        });
    }
    // The resume footer is hard-coded (Steve's call): the PDF link has no DSL row.
    try out.appendSlice(alloc,
        "</div>\n<p style=\"margin-top:28px;font-size:13px;color:#888\">" ++
        "<a href=\"/steve-resume\">Resume for Steve Howell</a> · <a href=\"/steve-resume.pdf\">PDF</a></p>\n" ++
        "</div></body></html>");
    return out.toOwnedSlice(alloc);
}

/// pushApp validates a fully-accumulated block and appends it. All fields are
/// required except `essay` (the optional "Read more" link) and `image` (the
/// optional app thumbnail) — a block missing any of title/href/cta/lang/tech/code/
/// description is malformed.
fn pushApp(alloc: Alloc, apps: *std.ArrayList(App), title: []const u8, href: []const u8, cta: []const u8, lang: []const u8, tech: []const u8, code: []const u8, essay: []const u8, image: []const u8, desc: *std.ArrayList(u8)) !void {
    if (title.len == 0 or href.len == 0 or cta.len == 0 or lang.len == 0 or tech.len == 0 or code.len == 0 or desc.items.len == 0) return error.MalformedHome;
    try apps.append(alloc, .{ .title = title, .href = href, .cta = cta, .lang = lang, .tech = tech, .code = code, .essay = essay, .image = image, .desc = try desc.toOwnedSlice(alloc) });
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
        "<a href=\"/\">Home</a> · <a href=\"/chat\">Chat</a> · <a href=\"/blog\">Blog</a></div>" ++
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
    \\<html><head><meta charset="utf-8"><title>Apps by Steve and Claude</title>
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
    \\/* The home launch pad: one row per app (replaces the old card grid) — a linked
    \\   title + description on the left, a uniform blue CTA button on the right. The
    \\   headline is deliberately quiet (.home-intro); the buttons are the loud thing. */
    \\.home-intro { margin: 14px 0 4px; font-size: 14px; font-weight: normal;
    \\              color: var(--cc-body-muted-fg, #444); }
    \\.app-list { margin-top: 8px; }
    \\/* The launch pad gets a wider column than the generic 820px wrap — the app rows
    \\   carry an image + paragraph + button side by side and the prose was cramped. */
    \\.home-wrap { max-width: 1040px; }
    \\.app-row { padding: 20px 0; border-bottom: 1px solid var(--cc-border, #e5e0d3); }
    \\.app-row:last-child { border-bottom: none; }
    \\.app-row-top { display: flex; align-items: flex-start; gap: 24px; }
    \\.app-thumb { flex-shrink: 0; display: block; line-height: 0; }
    \\.app-thumb img { width: 220px; height: 154px; display: block; border-radius: 8px;
    \\                 box-shadow: 0 1px 5px rgba(0,0,32,0.20); }
    \\.app-thumb:hover img { box-shadow: 0 2px 10px rgba(0,0,32,0.32); }
    \\.app-row-main { flex: 1; min-width: 0; }
    \\.app-row-main h2 { margin: 0 0 4px; font-size: 22px; }
    \\.app-row-main h2 a { color: var(--cc-accent, #000080); text-decoration: none; }
    \\.app-row-main h2 a:hover { text-decoration: underline; }
    \\.app-row-main p { margin: 0; color: var(--cc-body-muted-fg, #444); font-size: 14px; line-height: 1.5; }
    \\.app-row-main .app-more { margin: 6px 0 0; font-size: 13px; }
    \\.app-more a { color: var(--cc-accent, #000080); text-decoration: none; font-weight: 600; }
    \\.app-more a:hover { text-decoration: underline; }
    \\.app-row .cta { flex-shrink: 0; }
    \\/* Uniform footprint: every button is the same width + a single line, so the
    \\   column reads as one tidy stack of identical calls to action. No arrow — a
    \\   right-pointing arrow on a right-edge button reads as "look away". */
    \\.play-btn { display: flex; align-items: center; justify-content: center;
    \\            box-sizing: border-box; width: 252px; padding: 14px 16px; white-space: nowrap;
    \\            background: #000080; color: white; border-radius: 8px; text-align: center;
    \\            text-decoration: none; font-weight: bold; font-size: 16px; line-height: 1.2;
    \\            box-shadow: 0 1px 3px rgba(0,0,32,0.28); transition: background .12s, transform .12s; }
    \\.play-btn:hover { background: #1414c8; transform: translateY(-1px); }
    \\/* Tech stack, inline in the text column: GitHub link rides the "Read more" line
    \\   (.app-more); the language chip leads the feature blurb (.app-feat). Low-key. */
    \\.app-feat { margin: 8px 0 0; font-size: 12px; color: var(--cc-muted-fg, #888); }
    \\.tech-lang { display: inline-block; background: var(--cc-accent-soft-bg, #eef0f8);
    \\             color: var(--cc-accent, #000080); border-radius: 4px; padding: 2px 8px;
    \\             font-weight: 600; font-size: 11px; margin-right: 6px; }
    \\.tech-code { margin-left: 16px; white-space: nowrap; font-weight: 600;
    \\             color: var(--cc-accent, #000080); text-decoration: none; }
    \\.tech-code:hover { text-decoration: underline; }
    \\@media (max-width: 600px) { .app-row-top { flex-direction: column; align-items: flex-start; gap: 12px; }
    \\                            .play-btn { width: 100%; } }
    \\</style>
    \\</head><body>
    \\
;

