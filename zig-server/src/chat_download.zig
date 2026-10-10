//! chat_download: the transcript download bundle —
//! the "d" hotkey's server side. GET <conv-base>/<sid>/download streams a
//! gzipped tar of one topic:
//!
//!   <sid>/<sid>.md         the literal transcript (same bytes as /raw)
//!   <sid>/<sid>.reactions.jsonl   the reaction sidecar, when anyone has reacted
//!   <sid>/uploads/<file>   every image in the topic's .uploads sidecar
//!
//! The .count companion, and any .lastauthor an older server left, are deliberately omitted (internal
//! bookkeeping, not the human transcript). A topic is small, so the whole bundle is built in
//! memory then gzipped — no streaming-response machinery. The tar headers are
//! ustar.zig's.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const store = @import("chat_store.zig");
const disk = @import("store.zig");
const flate = std.compress.flate;
const ustar = @import("ustar.zig");

const Request = std.http.Server.Request;

/// serveBundle responds with the topic's .tar.gz, or 404 when the transcript is
/// missing/unreadable (don't distinguish — same as /raw).
pub fn serveBundle(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    const md_name = try std.fmt.allocPrint(alloc, "{s}.md", .{sid});
    const md_path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", md_name });
    const md = (try disk.readOrNull(io, alloc, md_path, .unlimited)) orelse return http.notFound(req);

    var tar: std.ArrayList(u8) = .empty;
    const md_entry = try std.fmt.allocPrint(alloc, "{s}/{s}.md", .{ sid, sid });
    try addTarFile(&tar, alloc, md_entry, md, fileMtime(io, alloc, md_path));

    // The reaction sidecar rides along when present (absent = nobody reacted).
    // Only absence leaves it out: a sidecar that cannot be read fails the
    // download rather than giving a bundle without it.
    const rx_path = try store.reactionsPath(alloc, conv_dir, sid);
    if (disk.read(io, alloc, rx_path, .unlimited)) |rx| {
        const rx_entry = try std.fmt.allocPrint(alloc, "{s}/{s}.reactions.jsonl", .{ sid, sid });
        try addTarFile(&tar, alloc, rx_entry, rx, fileMtime(io, alloc, rx_path));
    } else |e| if (e != error.FileNotFound) return e;

    // Images — append-only once written, so an unlocked read is safe. No
    // folder is no images yet; any other failure, the folder's or an image's,
    // fails the download: a bundle is the whole topic or nothing.
    const updir_name = try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid});
    const updir = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", updir_name });
    if (disk.list(io, alloc, updir)) |entries| {
        for (entries) |entry| {
            if (entry.kind == .directory) continue;
            const p = try std.fs.path.join(alloc, &.{ updir, entry.name });
            const data = try disk.read(io, alloc, p, .unlimited);
            const nm = try std.fmt.allocPrint(alloc, "{s}/uploads/{s}", .{ sid, entry.name });
            try addTarFile(&tar, alloc, nm, data, fileMtime(io, alloc, p));
        }
    } else |e| if (e != error.FileNotFound) return e;

    // Two zero blocks terminate a tar archive.
    try tar.appendNTimes(alloc, 0, 512 * 2);

    const gz = try gzipBytes(alloc, tar.items);
    const disp = try std.fmt.allocPrint(alloc, "attachment; filename=\"{s}.tar.gz\"", .{sid});
    try req.respond(gz, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "application/gzip" },
        .{ .name = "content-disposition", .value = disp },
    } });
}

/// fileMtime returns a file's mtime in whole Unix seconds, or 0 on any error
/// (the mtime is cosmetic in the archive, so 0 is harmless).
fn fileMtime(io: Io, alloc: Alloc, path: []const u8) u64 {
    // absent-ok: cosmetic: an archive member dated 1970 is still the member.
    const st = disk.stat(io, alloc, path) catch return 0;
    const s = @divFloor(st.mtime, std.time.ns_per_s);
    return if (s < 0) 0 else @intCast(s);
}

// ── ustar tar writer (hand-rolled — one regular file per 512-byte header) ─────

/// addTarFile appends one regular-file entry (a 512-byte ustar header and the
/// data padded to a 512-byte boundary) to `tar`. A name ustar cannot hold is
/// an error (ustar.zig), never cut.
fn addTarFile(tar: *std.ArrayList(u8), alloc: Alloc, name: []const u8, data: []const u8, mtime: u64) !void {
    const hdr = try ustar.header(name, data.len, mtime, '0');
    try tar.appendSlice(alloc, &hdr);
    try tar.appendSlice(alloc, data);
    const pad = (512 - (data.len % 512)) % 512;
    try tar.appendNTimes(alloc, 0, pad);
}

// ── gzip (whole-bundle, in memory) ────────────────────────────────────────────

/// gzipBytes returns `src` gzip-compressed. The deflate window is heap-allocated
/// (64 KiB) to keep the connection task's stack small; the output grows an
/// allocating writer we hand back as an owned slice.
fn gzipBytes(alloc: Alloc, src: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    const window = try alloc.alloc(u8, flate.max_window_len);
    var c = try flate.Compress.init(&out.writer, window, .gzip, flate.Compress.Options.default);
    try c.writer.writeAll(src);
    try c.finish();
    return out.written();
}
