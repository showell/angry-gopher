//! brand: /images/{file} — shared brand/avatar assets served from an EXPLICIT
//! allowlist. Not to be confused with images.zig (/chat/images — the per-user
//! chat image transcript); these are the binary's own brand images, embedded at
//! build time (build.zig). Public.
//!
//! The allowlist IS the path guard — no directory walk, no traversal surface.
//! Adding an image is two edits: a build.zig embed + one line in assetFor here.

const std = @import("std");
const http = @import("http.zig");

const Request = std.http.Server.Request;

const cat_professor = @embedFile("image_cat_professor");

/// handle serves /images/{file} — `sub` is the path after "/images" (e.g.
/// "/cat_professor.webp"). A non-allowlisted (or non-single-segment) file 404s.
pub fn handle(req: *Request, sub: []const u8) !void {
    if (sub.len == 0 or sub[0] != '/') return http.notFound(req);
    const file = sub[1..];
    const bytes = assetFor(file) orelse return http.notFound(req);
    try req.respond(bytes, .{ .extra_headers = &.{.{ .name = "content-type", .value = contentType(file) }} });
}

/// assetFor maps an allowlisted filename to its embedded bytes, or null.
fn assetFor(file: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, file, "cat_professor.webp")) return cat_professor;
    return null;
}

/// contentType derives the MIME type from the extension. Only the extensions the
/// binary actually hosts are wired.
fn contentType(file: []const u8) []const u8 {
    if (std.mem.endsWith(u8, file, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, file, ".png")) return "image/png";
    if (std.mem.endsWith(u8, file, ".svg")) return "image/svg+xml";
    return "application/octet-stream";
}
