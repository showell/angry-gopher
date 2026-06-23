//! blog: /blog — a public, read-only blog. Posts are markdown files that live in
//! the repo at blog/posts/<YYYY-MM-DD>-<slug>.md and are rsync'd to the droplet
//! by ops/deploy (NOT @embedFile'd — they're free-standing content, not built
//! artifacts, so editing a post is a content change, not a recompile). The server
//! reads them from `blog_root` at request time.
//!
//! Metadata has a single source of truth and no parser:
//!   - the FILENAME gives the date (`2026-06-23`) and the URL slug
//!     (`single-zig-binary`); the index sorts by filename desc = newest first.
//!   - the first `# H1` line in the file gives the display title (and renders
//!     naturally at the top of the post — no duplicated front-matter).
//!
//! Public surface: like "/", anon visitors get the same page (the top bar shows
//! "Log in"); reading never gates. Bodies render through markdown.renderTrusted —
//! the content is server-owned (in the repo), so it's exempt from render()'s
//! hostile-token cap exactly like the curated Links page.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const markdown = @import("markdown.zig");
const html = @import("html.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// blog_root is the directory of post files. The default is repo-relative, which
/// resolves in BOTH environments: ops/start runs the binary with cwd = repo root,
/// and the systemd unit's WorkingDirectory = the deploy dir (where ops/deploy
/// rsyncs blog/posts/). Override via the `blog_dir` config key if ever needed.
pub var blog_root: []const u8 = "blog/posts";

/// A post's metadata, parsed from its filename + first H1. `file` is the on-disk
/// name (kept so the post route can re-open exactly the enumerated file rather
/// than rebuild a path from request input — no traversal surface).
const PostMeta = struct {
    file: []const u8, // e.g. "2026-06-23-single-zig-binary.md"
    slug: []const u8, // e.g. "single-zig-binary" (the URL tail)
    date: []const u8, // e.g. "2026-06-23"
    title: []const u8, // first "# " line, or the prettified slug as a fallback
};

/// handle serves /blog (index) and /blog/<slug> (one post). `uid` is the resolved
/// viewer ("" for anon) — used only for the top bar; reading never gates.
pub fn handle(req: *Request, io: Io, alloc: Alloc, uid: []const u8, rest: []const u8) !void {
    const name = if (uid.len == 0) "" else try users.getUserName(io, alloc, uid);

    if (rest.len == 0 or std.mem.eql(u8, rest, "/")) {
        return renderIndex(req, io, alloc, name);
    }
    // /blog/<slug> — strip the leading '/'. A trailing slash or sub-path 404s.
    const slug = rest[1..];
    if (slug.len == 0 or std.mem.indexOfScalar(u8, slug, '/') != null) return http.notFound(req);
    return renderPost(req, io, alloc, name, slug);
}

/// renderIndex lists every post, newest first (filename desc), as title + date.
fn renderIndex(req: *Request, io: Io, alloc: Alloc, name: []const u8) !void {
    const metas = try listPosts(io, alloc);

    var b: std.ArrayList(u8) = .empty;
    try begin(&b, alloc, "Blog", name);
    try b.appendSlice(alloc, "<h1>Blog</h1>");
    if (metas.len == 0) {
        try b.appendSlice(alloc, "<p class=\"muted\">No posts yet.</p>");
    } else {
        try b.appendSlice(alloc, "<ul class=\"post-list\">");
        for (metas) |m| {
            try b.print(alloc,
                "<li><a href=\"/blog/{s}\">{s}</a><span class=\"post-date\">{s}</span></li>",
                .{ m.slug, try html.htmlEscape(alloc, m.title), m.date },
            );
        }
        try b.appendSlice(alloc, "</ul>");
    }
    try end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// renderPost serves one post by slug. The body renders whole (its own H1 is the
/// on-page title); a date line sits above it. Unknown slug → 404.
fn renderPost(req: *Request, io: Io, alloc: Alloc, name: []const u8, slug: []const u8) !void {
    const metas = try listPosts(io, alloc);
    const meta = for (metas) |m| {
        if (std.mem.eql(u8, m.slug, slug)) break m;
    } else return http.notFound(req);

    const path = try std.fs.path.join(alloc, &.{ blog_root, meta.file });
    const src = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return http.notFound(req);

    var b: std.ArrayList(u8) = .empty;
    try begin(&b, alloc, meta.title, name);
    try b.appendSlice(alloc, "<p class=\"back\"><a href=\"/blog\">← Blog</a></p>");
    try b.print(alloc, "<p class=\"post-date\">{s}</p>", .{meta.date});
    try b.appendSlice(alloc, try markdown.renderTrusted(alloc, src));
    try end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// listPosts enumerates blog_root, parses each well-named file's metadata, and
/// returns them sorted newest-first (filename desc). A missing dir means "no
/// posts," not an error. Files that don't match the date-prefix convention are
/// skipped (so a stray README.md or dotfile is ignored).
fn listPosts(io: Io, alloc: Alloc) ![]PostMeta {
    var dir = Io.Dir.cwd().openDir(io, blog_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList(PostMeta) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const file = try alloc.dupe(u8, entry.name);
        const parsed = parseFileName(file) orelse continue;
        const title = try readTitle(io, alloc, file, parsed.slug);
        try out.append(alloc, .{ .file = file, .slug = parsed.slug, .date = parsed.date, .title = title });
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(PostMeta, slice, {}, newestFirst);
    return slice;
}

fn newestFirst(_: void, a: PostMeta, b: PostMeta) bool {
    return std.mem.lessThan(u8, b.file, a.file); // filename desc = date desc
}

/// parseFileName splits "YYYY-MM-DD-slug.md" into its date and slug, validating
/// the date prefix and slug charset. Returns null for any non-conforming name —
/// the slug is the URL tail, so its charset is the public route's safety bound.
fn parseFileName(file: []const u8) ?struct { date: []const u8, slug: []const u8 } {
    if (!std.mem.endsWith(u8, file, ".md")) return null;
    const stem = file[0 .. file.len - ".md".len];
    // Need "YYYY-MM-DD-" (11 chars) then a non-empty slug.
    if (stem.len < 12) return null;
    const date = stem[0..10];
    if (!isIsoDate(date)) return null;
    if (stem[10] != '-') return null;
    const slug = stem[11..];
    if (slug.len == 0 or !isSlug(slug)) return null;
    return .{ .date = date, .slug = slug };
}

fn isIsoDate(s: []const u8) bool {
    if (s.len != 10) return false;
    for (s, 0..) |c, i| {
        if (i == 4 or i == 7) {
            if (c != '-') return false;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// isSlug: lowercase letters, digits, and hyphens only. Keeps the URL tail safe
/// (no '/', '.', '%' — no traversal or escaping) and tidy.
fn isSlug(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or std.ascii.isDigit(c) or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// readTitle returns the first "# " heading text from the file, or a prettified
/// slug if the file has none / can't be read. Single source of truth = the file.
fn readTitle(io: Io, alloc: Alloc, file: []const u8, slug: []const u8) ![]const u8 {
    const path = try std.fs.path.join(alloc, &.{ blog_root, file });
    const src = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch
        return prettifySlug(alloc, slug);
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "# ")) {
            return alloc.dupe(u8, std.mem.trim(u8, line[2..], " \t"));
        }
    }
    return prettifySlug(alloc, slug);
}

/// prettifySlug turns "single-zig-binary" into "Single zig binary" (hyphens to
/// spaces, first letter upper). Only used when a file lacks an H1.
fn prettifySlug(alloc: Alloc, slug: []const u8) ![]const u8 {
    const t = try std.mem.replaceOwned(u8, alloc, slug, "-", " ");
    if (t.len > 0) t[0] = std.ascii.toUpper(t[0]);
    return t;
}

// ── public chrome ──────────────────────────────────────────────────────────────
// A small self-contained shell, like home.zig's. The blog is a PUBLIC surface
// (not the logged-in chat sub-nav), so it gets the generic top bar — Home · Chat ·
// Blog — and a readable text column, rather than chrome.zig's chat chrome.

fn begin(b: *std.ArrayList(u8), alloc: Alloc, tab_title: []const u8, name: []const u8) !void {
    try b.appendSlice(alloc, head_a);
    try b.appendSlice(alloc, try html.htmlEscape(alloc, tab_title));
    try b.appendSlice(alloc, head_b);
    // Top bar: generic app chrome, "Blog" bolded as the active surface.
    try b.appendSlice(alloc,
        "<header class=\"app-top\"><div class=\"app-top-home\">" ++
        "<a href=\"/\">Lyn Rummy</a> · <a href=\"/chat\">Chat</a> · <strong>Blog</strong></div>" ++
        "<div class=\"app-top-user\">");
    if (name.len == 0) {
        try b.appendSlice(alloc, "<a href=\"/login\">Log in</a>");
    } else {
        try b.print(alloc, "<strong>{s}</strong> · <a href=\"/logout\">Log out</a>", .{try html.htmlEscape(alloc, name)});
    }
    try b.appendSlice(alloc, "</div></header><div class=\"blog-wrap\">");
}

fn end(b: *std.ArrayList(u8), alloc: Alloc) !void {
    try b.appendSlice(alloc, "</div></body></html>");
}

const head_a =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>
;
const head_b =
    \\</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 0; padding: 0; }
    \\.app-top { background: #f0ede4; border-bottom: 1px solid #c9bfa7; padding: 8px 24px;
    \\           display: flex; justify-content: space-between; align-items: baseline;
    \\           position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: #000080; text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.app-top-user { font-size: 13px; color: #444; }
    \\.app-top-user a { color: #000080; }
    \\.blog-wrap { max-width: 46rem; margin: 32px auto; padding: 0 24px 60px; line-height: 1.6; }
    \\.blog-wrap h1 { color: #000080; }
    \\.blog-wrap h2 { color: #000080; margin-top: 1.8rem; }
    \\.blog-wrap a { color: #000080; }
    \\.muted { color: #888; }
    \\.back a { font-size: 13px; text-decoration: none; }
    \\.post-date { color: #888; font-size: 13px; margin: 0 0 1.4rem; }
    \\ul.post-list { list-style: none; padding: 0; }
    \\ul.post-list li { padding: 8px 0; border-bottom: 1px solid #eee; display: flex;
    \\                  justify-content: space-between; align-items: baseline; gap: 16px; }
    \\ul.post-list a { color: #000080; text-decoration: none; font-weight: bold; font-size: 17px; }
    \\ul.post-list a:hover { text-decoration: underline; }
    \\ul.post-list .post-date { margin: 0; white-space: nowrap; }
    \\</style>
    \\</head><body>
    \\
;
