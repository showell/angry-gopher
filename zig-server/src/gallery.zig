//! gallery: a HIDDEN-for-now preview surface at /gallery — the stylized,
//! somewhat-faithful app images destined for the home page, before they're wired
//! in. Unlinked (no nav points here) but public + ungated; it leaks nothing.
//!
//! Images are free-standing CONTENT, read from `gallery_root` at request time
//! (like blog posts + pages/, rsync'd on deploy — NOT @embedFile'd). The index
//! shows one card per app in home-page order: the image if `gallery/<slug>.png`
//! (or `.svg`) exists, else a "pending" placeholder, so it doubles as a progress
//! view over the six-app set.
//!
//!   GET /gallery            the preview index (a card per app)
//!   GET /gallery/<file>     one image (png/svg), served from gallery_root

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const html = @import("html.zig");

const Request = std.http.Server.Request;

/// gallery_root is the image directory. Repo-relative default resolves both
/// locally (ops/start runs with cwd = repo root) and on the droplet (systemd
/// WorkingDirectory = the deploy dir, where ops/deploy rsyncs gallery/).
pub var gallery_root: []const u8 = "gallery";

/// One card per app, in the same order as pages/home.txt. `slug` is the image
/// basename we look for (gallery/<slug>.png|svg); `label` is the caption.
const Slot = struct { slug: []const u8, label: []const u8 };
const slots = [_]Slot{
    .{ .slug = "safari", .label = "Safari Screensaver" },
    .{ .slug = "chat", .label = "Chat" },
    .{ .slug = "blog", .label = "Blog" },
    .{ .slug = "delivery", .label = "Seattle Delivery" },
    .{ .slug = "lynrummy", .label = "Play Lyn Rummy" },
    .{ .slug = "puzzles", .label = "Lyn Rummy Puzzles" },
    .{ .slug = "chess", .label = "Chess Toys" },
};

/// handle dispatches /gallery* — `sub` is the path after "/gallery".
pub fn handle(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) return renderIndex(req, io, alloc);
    return serveImage(req, io, alloc, sub[1..]); // sub starts with '/'
}

// ── index ───────────────────────────────────────────────────────────────────

fn renderIndex(req: *Request, io: Io, alloc: Alloc) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, page_head);
    for (slots) |s| {
        try b.appendSlice(alloc, "<figure class=\"card\">");
        if (try imageFile(io, alloc, s.slug)) |file| {
            try b.print(alloc, "<img src=\"/gallery/{s}\" alt=\"{s}\">", .{
                try html.htmlEscape(alloc, file),
                try html.htmlEscape(alloc, s.label),
            });
        } else {
            try b.appendSlice(alloc, "<div class=\"pending\">pending</div>");
        }
        try b.print(alloc, "<figcaption>{s}</figcaption></figure>", .{try html.htmlEscape(alloc, s.label)});
    }
    try b.appendSlice(alloc, "</main></body></html>");
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// imageFile returns the basename of the existing image for `slug` (preferring
/// .png, then .svg), or null if neither is present.
fn imageFile(io: Io, alloc: Alloc, slug: []const u8) !?[]const u8 {
    for ([_][]const u8{ "png", "svg" }) |ext| {
        const name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ slug, ext });
        const path = try std.fs.path.join(alloc, &.{ gallery_root, name });
        if (Io.Dir.cwd().statFile(io, path, .{})) |_| return name else |_| {}
    }
    return null;
}

// ── one image ─────────────────────────────────────────────────────────────────

/// serveImage serves `name` (a bare basename) from gallery_root. The name is
/// validated to a safe charset with a png/svg extension — no slashes, no traversal,
/// so the request can never escape gallery_root.
fn serveImage(req: *Request, io: Io, alloc: Alloc, name: []const u8) !void {
    const ct = imageContentType(name) orelse return http.notFound(req);
    if (!isSafeName(name)) return http.notFound(req);
    const path = try std.fs.path.join(alloc, &.{ gallery_root, name });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return http.notFound(req);
    try req.respond(bytes, .{ .extra_headers = &.{ct} });
}

/// imageContentType maps a known image extension to its header, or null.
fn imageContentType(name: []const u8) ?std.http.Header {
    if (std.mem.endsWith(u8, name, ".png")) return http.png_ct;
    if (std.mem.endsWith(u8, name, ".svg")) return http.svg_ct;
    return null;
}

/// isSafeName allows only `[A-Za-z0-9._-]` — no path separators, so no traversal
/// (a `.` is fine; a `..` segment needs a `/` to escape, which is rejected).
fn isSafeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ── markup ──────────────────────────────────────────────────────────────────

const page_head =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>Gallery (preview)</title>
    \\<style>
    \\body { margin: 0; background: #14151a; color: #cfd2d6;
    \\       font-family: system-ui, sans-serif; }
    \\h1 { color: #e6e8eb; font-size: 20px; font-weight: 600; margin: 0 0 4px; }
    \\.intro { color: #888; font-size: 13px; margin: 0 0 24px; }
    \\nav { font-size: 13px; margin-bottom: 16px; } nav a { color: #8fb6e6; }
    \\main { max-width: 1100px; margin: 0 auto; padding: 32px 28px 56px;
    \\       display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
    \\       gap: 20px; }
    \\.head { grid-column: 1 / -1; }
    \\figure.card { margin: 0; background: #1d1f26; border: 1px solid #2a2d36;
    \\              border-radius: 8px; overflow: hidden; }
    \\figure.card img { display: block; width: 100%; height: auto; background: #000; }
    \\.pending { aspect-ratio: 600 / 420; display: flex; align-items: center;
    \\           justify-content: center; color: #555; font-size: 14px;
    \\           letter-spacing: 1px; text-transform: uppercase; background: #16171c; }
    \\figcaption { padding: 10px 14px; font-size: 14px; color: #cfd2d6; }
    \\</style>
    \\</head><body>
    \\<main>
    \\<div class="head">
    \\<nav><a href="/">&larr; Home</a></nav>
    \\<h1>Gallery <span style="color:#666;font-weight:400">· preview</span></h1>
    \\<p class="intro">Stylized, somewhat-faithful images for each app — one-time renders, not screenshots. Not yet linked from the home page.</p>
    \\</div>
    \\
;
