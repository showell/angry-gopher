//! safari_download: /safari_download — a short "install the screensaver" page. It
//! carries the native download links (the Windows .scr + the Linux X11 binary) and
//! the per-OS setup notes; the home page's Safari row links here ("Install locally")
//! instead of pointing straight at one platform's binary.
//!
//! The page body is server-owned prose in pages/safari-download.md, rendered through
//! the SAME trusted markdown pipeline as the blog + resume (renderTrustedReflow, so
//! paragraphs reflow to the viewport). Like the resume it's free-standing content —
//! read from disk at request time and rsync'd on deploy, NOT @embedFile'd — so
//! editing the instructions is a content change, not a recompile.
//!
//! The binaries themselves are served by downloads.zig from downloads/ (the .md just
//! links to /downloads/safari-windows.scr and /downloads/safari-linux); that's the
//! existing free-standing-download precedent this page is a landing surface for.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const markdown = @import("markdown.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// page_path is the markdown source, repo-relative so it resolves in BOTH
/// environments: ops/start runs with cwd = repo root, and the systemd unit's
/// WorkingDirectory = the deploy dir (where ops/deploy rsyncs pages/).
pub var page_path: []const u8 = "pages/safari-download.md";

/// handle serves GET /safari_download. A missing source file 404s (rather than
/// crashing) — the route exists only when the content does.
pub fn handle(req: *Request, io: Io, alloc: Alloc) !void {
    const src = Io.Dir.cwd().readFileAlloc(io, page_path, alloc, .unlimited) catch return http.notFound(req);

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, page_head);
    // Server-owned body: the trusted (uncapped) reflow render, like the blog's prose.
    try b.appendSlice(alloc, try markdown.renderTrustedReflow(alloc, src));
    try b.appendSlice(alloc, page_tail);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// A small self-contained shell — a readable text column on the generic top bar,
// mirroring resume_page.zig's chrome. Adds a touch of code-block styling so the
// shell commands read as a block.
const page_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Install the Safari Screensaver</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 0; padding: 0; color: #1a1a1a; }
    \\.app-top { background: #f0ede4; border-bottom: 1px solid #c9bfa7; padding: 8px 24px;
    \\           display: flex; justify-content: space-between; align-items: baseline;
    \\           position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: #000080; text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.doc-wrap { max-width: 46rem; margin: 32px auto; padding: 0 24px 60px; line-height: 1.55; }
    \\.doc-wrap h1 { color: #000080; margin-bottom: 0.2rem; }
    \\.doc-wrap h2 { color: #000080; margin-top: 2rem; border-bottom: 1px solid #c9bfa7; padding-bottom: 4px; }
    \\.doc-wrap a { color: #000080; }
    \\.doc-wrap code { background: #f0ede4; padding: 1px 5px; border-radius: 3px; font-size: 0.92em; }
    \\.doc-wrap pre { background: #f6f4ee; border: 1px solid #e0d9c6; border-radius: 6px;
    \\                padding: 12px 14px; overflow-x: auto; }
    \\.doc-wrap pre code { background: none; padding: 0; }
    \\</style>
    \\</head><body>
    \\<header class="app-top"><div class="app-top-home">
    \\<a href="/">Home</a> · <a href="/chat">Chat</a> · <a href="/blog">Blog</a></div></header>
    \\<div class="doc-wrap">
    \\
;

const page_tail =
    \\</div></body></html>
;
