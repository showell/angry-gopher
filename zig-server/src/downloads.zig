//! downloads: free-standing downloadable artifacts at /downloads/<file> — the native
//! Safari Screensaver builds linked from the /safari_download page: the Linux X11
//! executable (safari-linux) and the Windows .scr (safari-windows.scr). Both are
//! built on deploy (ops/build_safari_download + ops/build_safari_windows) and rsync'd
//! to `downloads/` — NOT @embedFile'd (they're big native binaries, and they ride
//! alongside the server like gallery/ + blog posts rather than bloating the server
//! binary they're served BY).
//!
//!   GET /downloads/<file>   one artifact, streamed as an attachment
//!
//! Files stream as application/octet-stream + Content-Disposition: attachment, so
//! the browser saves them rather than trying to render. Locally (ops/start) the
//! downloads/ dir usually doesn't exist, so the link 404s until a deploy populates
//! it on the host — the same free-standing-content posture as gallery images.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");

const Request = std.http.Server.Request;

/// downloads_root is the artifact directory. Repo-relative default resolves on
/// the droplet (systemd WorkingDirectory = the deploy dir, where ops/deploy
/// rsyncs downloads/); locally it's usually absent, so requests 404.
pub var downloads_root: []const u8 = "downloads";

/// handle dispatches /downloads* — `sub` is the path after "/downloads".
pub fn handle(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) return http.notFound(req);
    return serve(req, io, alloc, sub[1..]); // sub starts with '/'
}

/// serve streams `name` (a bare basename) from downloads_root as an attachment.
/// The name is validated to a safe charset — no slashes, no traversal — so the
/// request can never escape downloads_root.
fn serve(req: *Request, io: Io, alloc: Alloc, name: []const u8) !void {
    if (!isSafeName(name)) return http.notFound(req);
    const path = try std.fs.path.join(alloc, &.{ downloads_root, name });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return http.notFound(req);
    const disposition = std.http.Header{
        .name = "content-disposition",
        .value = try std.fmt.allocPrint(alloc, "attachment; filename=\"{s}\"", .{name}),
    };
    try req.respond(bytes, .{ .extra_headers = &.{ http.octet_ct, disposition } });
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
