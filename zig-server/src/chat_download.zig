//! chat_download: the transcript download bundle (port of chat_download.go) —
//! the "d" hotkey's server side. GET <conv-base>/<sid>/download streams a
//! gzipped tar of one topic:
//!
//!   <sid>/<sid>.md         the literal transcript (same bytes as /raw)
//!   <sid>/uploads/<file>   every image in the topic's .uploads sidecar
//!
//! The .lastauthor companion is deliberately omitted (internal bookkeeping, not
//! the human transcript). A topic is small, so the whole bundle is built in
//! memory then gzipped — no streaming-response machinery. The tar headers are
//! hand-rolled ustar (Go leans on archive/tar; zig std has no tar writer).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const flate = std.compress.flate;

const Request = std.http.Server.Request;

/// serveBundle responds with the topic's .tar.gz, or 404 when the transcript is
/// missing/unreadable (don't distinguish — same as /raw). Mirrors Go's
/// serveTranscriptBundle.
pub fn serveBundle(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    const md_name = try std.fmt.allocPrint(alloc, "{s}.md", .{sid});
    const md_path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", md_name });
    const md = Io.Dir.cwd().readFileAlloc(io, md_path, alloc, .unlimited) catch return http.notFound(req);

    var tar: std.ArrayList(u8) = .empty;
    const md_entry = try std.fmt.allocPrint(alloc, "{s}/{s}.md", .{ sid, sid });
    try addTarFile(&tar, alloc, md_entry, md, fileMtime(io, md_path));

    // Images — append-only once written, so an unlocked read is safe. A missing
    // dir (no images yet) yields nothing; an unreadable file is skipped, not fatal.
    const updir_name = try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid});
    const updir = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", updir_name });
    if (Io.Dir.cwd().openDir(io, updir, .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            const p = try std.fs.path.join(alloc, &.{ updir, entry.name });
            const data = Io.Dir.cwd().readFileAlloc(io, p, alloc, .unlimited) catch continue;
            const nm = try std.fmt.allocPrint(alloc, "{s}/uploads/{s}", .{ sid, entry.name });
            try addTarFile(&tar, alloc, nm, data, fileMtime(io, p));
        }
    } else |_| {}

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
/// (cosmetic in the archive — Go falls back to now; 0 is just as harmless).
fn fileMtime(io: Io, path: []const u8) u64 {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    const s = @divFloor(st.mtime.nanoseconds, std.time.ns_per_s);
    return if (s < 0) 0 else @intCast(s);
}

// ── ustar tar writer (hand-rolled — one regular file per 512-byte header) ─────

/// addTarFile appends one regular-file entry (a 512-byte ustar header + the data
/// padded to a 512-byte boundary) to `tar`. `name` is truncated to the 100-byte
/// name field (our paths are short: "<sid>/<sid>.md", "<sid>/uploads/<hex>.png").
fn addTarFile(tar: *std.ArrayList(u8), alloc: Alloc, name: []const u8, data: []const u8, mtime: u64) !void {
    var hdr: [512]u8 = @splat(0);
    const nlen = @min(name.len, 100);
    @memcpy(hdr[0..nlen], name[0..nlen]);
    octalField(hdr[100..108], 0o644); // mode
    octalField(hdr[108..116], 0); // uid
    octalField(hdr[116..124], 0); // gid
    octalField(hdr[124..136], data.len); // size
    octalField(hdr[136..148], mtime); // mtime
    @memset(hdr[148..156], ' '); // chksum field = spaces while summing
    hdr[156] = '0'; // typeflag: regular file
    @memcpy(hdr[257..263], "ustar\x00"); // magic
    hdr[263] = '0'; // version "00"
    hdr[264] = '0';

    var sum: u32 = 0;
    for (hdr) |c| sum += c;
    octalDigits(hdr[148..154], sum); // 6 octal digits …
    hdr[154] = 0; // … NUL …
    hdr[155] = ' '; // … space (the ustar chksum convention)

    try tar.appendSlice(alloc, &hdr);
    try tar.appendSlice(alloc, data);
    const pad = (512 - (data.len % 512)) % 512;
    try tar.appendNTimes(alloc, 0, pad);
}

/// octalField writes `value` as (field.len - 1) zero-padded octal digits followed
/// by a trailing NUL — the ustar numeric-field convention (mode/uid/gid/size/mtime).
fn octalField(field: []u8, value: u64) void {
    const digits = field.len - 1;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    field[digits] = 0;
}

/// octalDigits fills `field` with exactly field.len zero-padded octal digits (no
/// terminator) — used for the checksum's 6-digit run.
fn octalDigits(field: []u8, value: u64) void {
    var v = value;
    var i = field.len;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
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
