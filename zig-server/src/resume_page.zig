//! resume_page: /steve-resume — Steve's resume as a single server-owned markdown
//! page, rendered through the SAME trusted markdown pipeline as the blog. The
//! source lives in the repo at pages/steve-resume.md and is rsync'd to the droplet
//! by ops/deploy (NOT @embedFile'd — it's free-standing content, so editing the
//! resume is a content change, not a recompile), read from `resume_root` at
//! request time.
//!
//! Renders with markdown.renderTrusted (the HARD-WRAP trusted variant, not the
//! blog's reflow): a resume's line breaks are meaningful — the contact block and
//! each role's italic date line must stay on their own lines — while a single
//! long prose line still wraps naturally to the viewport. The body is server-
//! owned (in the repo), so it's exempt from render()'s hostile-token cap exactly
//! like the blog and the curated Links page.
//!
//! The module name avoids `resume` (a zig keyword for async resume); the import
//! binding in server.zig is `resume_page`.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const markdown = @import("markdown.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// resume_path is the markdown source, repo-relative so it resolves in BOTH
/// environments: ops/start runs with cwd = repo root, and the systemd unit's
/// WorkingDirectory = the deploy dir (where ops/deploy rsyncs pages/).
pub var resume_path: []const u8 = "pages/steve-resume.md";

/// handle serves GET /steve-resume. A missing source file 404s (rather than
/// crashing) — the route exists only when the content does.
pub fn handle(req: *Request, io: Io, alloc: Alloc) !void {
    const src = Io.Dir.cwd().readFileAlloc(io, resume_path, alloc, .unlimited) catch return http.notFound(req);

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, page_head);
    // Server-owned body: the trusted (uncapped) hard-wrap render.
    try b.appendSlice(alloc, try markdown.renderTrusted(alloc, src));
    try b.appendSlice(alloc, page_tail);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// A small self-contained shell — a readable text column on the generic top bar,
// mirroring blog.zig's chrome. Print-friendly (the top bar drops away on @media
// print) so "save as PDF" from the browser yields a clean page too.
const page_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Steve Howell — Résumé</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 0; padding: 0; color: #1a1a1a; }
    \\.app-top { background: #f0ede4; border-bottom: 1px solid #c9bfa7; padding: 8px 24px;
    \\           display: flex; justify-content: space-between; align-items: baseline;
    \\           position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: #000080; text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.resume-wrap { max-width: 46rem; margin: 32px auto; padding: 0 24px 60px; line-height: 1.55; }
    \\.resume-wrap h1 { color: #000080; margin-bottom: 0.2rem; }
    \\.resume-wrap h2 { color: #000080; margin-top: 2rem; border-bottom: 1px solid #c9bfa7; padding-bottom: 4px; }
    \\.resume-wrap h3 { margin-top: 1.5rem; margin-bottom: 0.2rem; }
    \\.resume-wrap em { color: #555; }
    \\.resume-wrap a { color: #000080; }
    \\.resume-wrap ul { padding-left: 1.2rem; }
    \\.resume-wrap li { margin: 3px 0; }
    \\@media print {
    \\  .app-top { display: none; }
    \\  .resume-wrap { margin: 0 auto; max-width: none; }
    \\}
    \\</style>
    \\</head><body>
    \\<header class="app-top"><div class="app-top-home">
    \\<a href="/">Lyn Rummy</a> · <a href="/chat">Chat</a> · <a href="/blog">Blog</a></div></header>
    \\<div class="resume-wrap">
    \\
;

const page_tail =
    \\</div></body></html>
;
