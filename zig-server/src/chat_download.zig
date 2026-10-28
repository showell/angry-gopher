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
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("webbox").http;
const store = @import("chat_store.zig");
const disk = @import("webbox").store;
const flate = std.compress.flate;
const ustar = @import("ustar.zig");

const Request = std.http.Server.Request;

/// **A TOPIC'S BUNDLE, BUILT A FILE AT A TIME** (Host.bundle_add! and
/// serve_bundle!, metal-vmm QUEUE 291): the Roc names each file and where it
/// goes in the tar (roc-webbox chat/main.roc `serve_download!`); this holds
/// the tar, then serves it gzipped.
pub const Bundle = struct {
    tar: std.ArrayList(u8) = .empty,

    /// The file at `path` as the entry `name`, dated by its mtime.
    pub fn add(b: *Bundle, io: Io, alloc: Alloc, name: []const u8, path: []const u8) !void {
        const data = try disk.read(
            io,
            alloc,
            path,
            .unlimited,
        );
        try addTarFile(
            &b.tar,
            alloc,
            name,
            data,
            fileMtime(
                io,
                alloc,
                path,
            ),
        );
    }

    /// The tar closed, gzipped and answered as the attachment `<name>.tar.gz`.
    pub fn serve(b: *Bundle, req: *Request, alloc: Alloc, name: []const u8) !void {
        // Two zero blocks terminate a tar archive.
        try b.tar.appendNTimes(
            alloc,
            0,
            512 * 2,
        );
        const gz = try gzipBytes(alloc, b.tar.items);
        const disp = try std.fmt.allocPrint(
            alloc,
            "attachment; filename=\"{s}.tar.gz\"",
            .{name},
        );
        try req.respond(gz, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/gzip" },
            .{ .name = "content-disposition", .value = disp },
        } });
    }
};

/// fileMtime returns a file's mtime in whole Unix seconds, or 0 on any error
/// (the mtime is cosmetic in the archive, so 0 is harmless).
fn fileMtime(
    io: Io,
    alloc: Alloc,
    path: []const u8,
) u64 {
    // absent-ok: cosmetic: an archive member dated 1970 is still the member.
    const st = disk.stat(
        io,
        alloc,
        path,
    ) catch return 0;
    const s = @divFloor(st.mtime, std.time.ns_per_s);
    return if (s < 0) 0 else @intCast(s);
}

// ── ustar tar writer (hand-rolled — one regular file per 512-byte header) ─────

/// addTarFile appends one regular-file entry (a 512-byte ustar header and the
/// data padded to a 512-byte boundary) to `tar`. A name ustar cannot hold is
/// an error (ustar.zig), never cut.
fn addTarFile(
    tar: *std.ArrayList(u8),
    alloc: Alloc,
    name: []const u8,
    data: []const u8,
    mtime: u64,
) !void {
    const hdr = try ustar.header(
        name,
        data.len,
        mtime,
        '0',
    );
    try tar.appendSlice(alloc, &hdr);
    try tar.appendSlice(alloc, data);
    const pad = (512 - (data.len % 512)) % 512;
    try tar.appendNTimes(
        alloc,
        0,
        pad,
    );
}

// ── gzip (whole-bundle, in memory) ────────────────────────────────────────────

/// gzipBytes returns `src` gzip-compressed. The deflate window is heap-allocated
/// (64 KiB) to keep the connection task's stack small; the output grows an
/// allocating writer we hand back as an owned slice.
fn gzipBytes(alloc: Alloc, src: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    const window = try alloc.alloc(u8, flate.max_window_len);
    var c = try flate.Compress.init(
        &out.writer,
        window,
        .gzip,
        flate.Compress.Options.default,
    );
    try c.writer.writeAll(src);
    try c.finish();
    return out.written();
}
