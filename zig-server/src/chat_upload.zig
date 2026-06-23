//! chat_upload: chat image AND screencast uploads.
//!   POST <conv-base>/<sid>/upload          store one image/video, return its URL
//!   GET  <conv-base>/<sid>/uploads/<file>  serve a stored image/video
//! Uploads land in the session's sidecar dir (sessions/<sid>.uploads/) under a
//! random unguessable name whose extension is derived from the SNIFFED magic
//! bytes (never the client's filename). Both DMs and channels route here; the
//! conv-base + sid + dir are supplied by the caller (chat.topicRoute), so this
//! module is shape-agnostic.
//!
//! Limits: a per-file cap that depends on kind (10 MiB image / 100 MiB video)
//! AND the shared per-user lifetime quota (screencasts draw the same allowance).
//! The serve path honors HTTP Range so video seeks/streams instead of forcing a
//! whole-file download (and bounds the bytes held in RAM per request).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const edge = @import("edge.zig");
const users = @import("users.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// max_any_upload bounds the body read before the kind is known (sniffing needs
/// the bytes in hand): the largest per-file cap across kinds, plus multipart
/// slack. The per-kind caps themselves live on UploadKind.cap().
const max_any_upload = @max(UploadKind.image.cap(), UploadKind.video.cap()) + (1 << 20);

/// range_window caps the bytes served for one Range request, so a single 206
/// (and its in-RAM buffer) stays bounded no matter how open-ended the range —
/// the browser just requests the next window as playback advances.
const range_window = 8 << 20; // 8 MiB

// ── write path (POST <base>/<sid>/upload) ─────────────────────────────────────

/// handleUpload accepts one multipart image/video upload, stores it in the
/// session's uploads sidecar under a random name (extension from sniffed magic
/// bytes), and returns {url, name, kind, width, height} JSON. `kind` is "image"
/// or "video" so the client inserts the right tag; width/height are 0 (we don't
/// decode dimensions — the client omits the attrs then, per its BROWSER_WORKAROUND).
pub fn handleUpload(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_dir: []const u8, base: []const u8, sid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    // Read the Content-Type (for the multipart boundary) BEFORE the body: reading
    // the body advances the reader past received_head (after which iterateHeaders
    // asserts, the /send gotcha) and invalidates the head strings. http.header
    // owns its result, so `ct` (and the boundary sliced from it) survive the body read.
    const ct = (try http.header(req, alloc, "content-type")) orelse return edge.reject(req, .malformed_multipart, "no file\n");
    const boundary = multipartBoundary(ct) orelse return edge.reject(req, .malformed_multipart, "no file\n");

    const body = (try http.readLimitedBody(req, alloc, max_any_upload)) orelse return;
    const part = parseMultipartFile(alloc, body, boundary) orelse
        return edge.reject(req, .malformed_multipart, "no file\n");

    // Sniff the kind FIRST — it carries the per-file cap and the user-facing noun.
    const sniff = detectUpload(part.data) orelse
        return req.respond("unsupported file type (images: png, jpeg, gif, webp; video: mp4, webm, mov)\n", .{ .status = .unsupported_media_type });
    if (part.data.len > sniff.kind.cap()) {
        const msg = try std.fmt.allocPrint(alloc, "{s} too large — the limit is {d} MB.\n", .{ sniff.kind.noun(), sniff.kind.cap() >> 20 });
        return edge.reject(req, .body_too_large, msg);
    }

    // Lifetime per-user quota — atomic add-if-under-cap. Images and screencasts
    // share the one allowance.
    if (!users.reserveUploadBytes(io, alloc, uid, @intCast(part.data.len))) {
        const msg = try std.fmt.allocPrint(alloc, "Upload limit reached — you've used your {d} GB upload allowance.\n", .{users.max_upload_lifetime_bytes >> 30});
        return req.respond(msg, .{ .status = .forbidden });
    }

    const token = randHex16(io, alloc) catch return req.respond("token\n", .{ .status = .internal_server_error });
    const name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ token, sniff.ext });
    const dir = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid}) });
    Io.Dir.cwd().createDirPath(io, dir) catch return req.respond("mkdir\n", .{ .status = .internal_server_error });
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = part.data }) catch
        return req.respond("write\n", .{ .status = .internal_server_error });

    const out = try std.fmt.allocPrint(alloc, "{{\"url\":\"{s}/{s}/uploads/{s}\",\"name\":{f},\"kind\":\"{s}\",\"width\":0,\"height\":0}}", .{
        base, sid, name, std.json.fmt(part.filename, .{}), @tagName(sniff.kind),
    });
    try req.respond(out, .{ .extra_headers = &.{http.json_ct} });
}

// ── serve path (GET <base>/<sid>/uploads/<file>) ──────────────────────────────

/// serveUpload serves a stored image/video so an `<img src>` / `<video src>`
/// resolves. The name must be 32 hex + a known ext; content-type by extension;
/// immutable private cache; nosniff. Path = conv_dir/sessions/<sid>.uploads/<file>.
///
/// A `Range:` request (how browsers fetch `<video>`) gets a 206 of one
/// `range_window` slice, read positionally so only that slice is in RAM; a plain
/// GET (images, direct download) gets the whole file as before. `accept-ranges`
/// is always advertised so the player knows it may seek.
pub fn serveUpload(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, file: []const u8) !void {
    const ct = uploadContentType(file) orelse return http.notFound(req);
    const updir = try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid});
    const path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", updir, file });

    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return http.notFound(req);
    defer f.close(io);
    const size = (f.stat(io) catch return http.notFound(req)).size;

    if (try http.header(req, alloc, "range")) |range_hdr| {
        const r = parseRange(range_hdr, size) orelse {
            const cr = try std.fmt.allocPrint(alloc, "bytes */{d}", .{size});
            return req.respond("", .{ .status = .range_not_satisfiable, .extra_headers = &.{
                .{ .name = "content-range", .value = cr },
                .{ .name = "accept-ranges", .value = "bytes" },
            } });
        };
        const len: usize = @intCast(r.end - r.start + 1);
        const buf = try alloc.alloc(u8, len);
        const n = f.readPositionalAll(io, buf, r.start) catch return http.notFound(req);
        const cr = try std.fmt.allocPrint(alloc, "bytes {d}-{d}/{d}", .{ r.start, r.start + n - 1, size });
        return req.respond(buf[0..n], .{ .status = .partial_content, .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            .{ .name = "content-range", .value = cr },
            .{ .name = "accept-ranges", .value = "bytes" },
            .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        } });
    }

    const data = try alloc.alloc(u8, @intCast(size));
    const n = f.readPositionalAll(io, data, 0) catch return http.notFound(req);
    try req.respond(data[0..n], .{ .extra_headers = &.{
        .{ .name = "content-type", .value = ct },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

const Range = struct { start: u64, end: u64 }; // inclusive byte offsets

/// parseRange reads a single-range `Range: bytes=…` header against a file of
/// `size` bytes, returning the inclusive [start, end] to serve — clamped to the
/// file AND to one `range_window` so the response stays bounded. Null on a
/// malformed or unsatisfiable range (caller answers 416). Multi-range (commas)
/// is unsupported — we serve the first range's window, which players accept.
fn parseRange(hdr: []const u8, size: u64) ?Range {
    if (size == 0) return null;
    const spec0 = if (std.mem.startsWith(u8, hdr, "bytes=")) hdr[6..] else return null;
    // Take only the first range if a comma-list was sent.
    const spec = if (std.mem.indexOfScalar(u8, spec0, ',')) |c| spec0[0..c] else spec0;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const left = std.mem.trim(u8, spec[0..dash], " ");
    const right = std.mem.trim(u8, spec[dash + 1 ..], " ");

    var start: u64 = undefined;
    var end: u64 = size - 1;
    if (left.len == 0) {
        // Suffix range: last N bytes.
        const suffix = std.fmt.parseInt(u64, right, 10) catch return null;
        if (suffix == 0) return null;
        start = if (suffix >= size) 0 else size - suffix;
    } else {
        start = std.fmt.parseInt(u64, left, 10) catch return null;
        if (start >= size) return null;
        if (right.len != 0) {
            const e = std.fmt.parseInt(u64, right, 10) catch return null;
            if (e < start) return null;
            end = @min(e, size - 1);
        }
    }
    end = @min(end, start + range_window - 1);
    return .{ .start = start, .end = end };
}

/// uploadContentType validates the served/on-disk filename
/// $`) and returns its MIME, or null — doubling
/// as the path-traversal guard for the file segment.
fn uploadContentType(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot != 32) return null;
    for (name[0..32]) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    }
    return extMime(name[dot + 1 ..]);
}

// ── helpers ───────────────────────────────────────────────────────────────────

const UploadKind = enum {
    image,
    video,

    /// per-file upload cap for this kind (the shared lifetime quota is separate).
    fn cap(k: UploadKind) usize {
        return switch (k) {
            .image => 10 << 20, // 10 MiB
            .video => 100 << 20, // 100 MiB
        };
    }
    /// the noun for this kind in size-limit messages.
    fn noun(k: UploadKind) []const u8 {
        return switch (k) {
            .image => "Image",
            .video => "Screencast",
        };
    }
};
const Sniffed = struct { ext: []const u8, kind: UploadKind };

/// detectUpload sniffs the magic bytes of every allowed type (image first, then
/// video) and returns our canonical extension + kind. We sniff rather than trust
/// the client's filename / Content-Type.
fn detectUpload(data: []const u8) ?Sniffed {
    if (detectImageExt(data)) |e| return .{ .ext = e, .kind = .image };
    if (detectVideoExt(data)) |e| return .{ .ext = e, .kind = .video };
    return null;
}

fn detectImageExt(data: []const u8) ?[]const u8 {
    if (data.len >= 8 and std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "png";
    if (data.len >= 3 and std.mem.startsWith(u8, data, "\xff\xd8\xff")) return "jpg";
    if (data.len >= 6 and (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a"))) return "gif";
    if (data.len >= 12 and std.mem.startsWith(u8, data, "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "webp";
    return null;
}

/// detectVideoExt sniffs the three screencast containers. WebM/Matroska open
/// with the EBML magic; mp4 and mov are both ISO-BMFF with an "ftyp" box at
/// offset 4 — the major brand at offset 8 ("qt  " = QuickTime) splits them.
fn detectVideoExt(data: []const u8) ?[]const u8 {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) return "webm";
    if (data.len >= 12 and std.mem.eql(u8, data[4..8], "ftyp")) {
        return if (std.mem.eql(u8, data[8..12], "qt  ")) "mov" else "mp4";
    }
    return null;
}

fn extMime(ext: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ext, "png")) return "image/png";
    if (std.mem.eql(u8, ext, "jpg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, "gif")) return "image/gif";
    if (std.mem.eql(u8, ext, "webp")) return "image/webp";
    if (std.mem.eql(u8, ext, "mp4")) return "video/mp4";
    if (std.mem.eql(u8, ext, "webm")) return "video/webm";
    if (std.mem.eql(u8, ext, "mov")) return "video/quicktime";
    return null;
}

/// randHex16 returns 16 CSPRNG bytes as 32 lowercase hex chars.
/// io.random is the OS-seeded secure RNG.
fn randHex16(io: Io, alloc: Alloc) ![]u8 {
    var buf: [16]u8 = undefined;
    io.random(buf[0..]);
    const hex = std.fmt.bytesToHex(buf, .lower); // [32]u8
    return alloc.dupe(u8, &hex);
}

const Part = struct { filename: []const u8, data: []const u8 };

/// multipartBoundary extracts the boundary token from a multipart Content-Type
/// (`multipart/form-data; boundary=…`), handling an optional quoted value.
fn multipartBoundary(ct: []const u8) ?[]const u8 {
    const p = std.mem.indexOf(u8, ct, "boundary=") orelse return null;
    var v = ct[p + "boundary=".len ..];
    if (v.len > 0 and v[0] == '"') {
        v = v[1..];
        const e = std.mem.indexOfScalar(u8, v, '"') orelse return null;
        return v[0..e];
    }
    if (std.mem.indexOfScalar(u8, v, ';')) |e| v = v[0..e];
    return std.mem.trim(u8, v, " \t\r\n");
}

/// parseMultipartFile returns the first part whose Content-Disposition name is
/// "file" (its filename + raw bytes), or null. A focused parser for the single
/// FormData field the compose client sends — not a general multipart decoder.
fn parseMultipartFile(alloc: Alloc, body: []const u8, boundary: []const u8) ?Part {
    const delim = std.fmt.allocPrint(alloc, "--{s}", .{boundary}) catch return null;
    var pos = std.mem.indexOf(u8, body, delim) orelse return null;
    while (true) {
        var i = pos + delim.len;
        if (i + 2 <= body.len and body[i] == '-' and body[i + 1] == '-') return null; // closing delimiter
        if (i + 2 <= body.len and body[i] == '\r' and body[i + 1] == '\n') i += 2;

        const hdr_rel = std.mem.indexOf(u8, body[i..], "\r\n\r\n") orelse return null;
        const headers = body[i .. i + hdr_rel];
        const data_start = i + hdr_rel + 4;
        // indexOfPos returns an ABSOLUTE index into body (not relative to data_start).
        const next_abs = std.mem.indexOfPos(u8, body, data_start, delim) orelse return null;
        var data_end = next_abs;
        if (data_end >= data_start + 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') data_end -= 2;

        if (attrVal(headers, "name")) |nm| {
            if (std.mem.eql(u8, nm, "file")) {
                return .{ .filename = attrVal(headers, "filename") orelse "image", .data = body[data_start..data_end] };
            }
        }
        pos = next_abs; // advance to the next part's delimiter
    }
}

/// attrVal pulls a quoted `<attr>="value"` out of a header block. Requires the
/// char before `attr` to be a non-letter so the `name` attr doesn't match inside
/// `filename`.
fn attrVal(headers: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, headers, i, attr)) |p| {
        i = p + attr.len;
        if (i + 1 >= headers.len or headers[i] != '=' or headers[i + 1] != '"') continue;
        if (p > 0 and isAlpha(headers[p - 1])) continue;
        const start = i + 2;
        const end = std.mem.indexOfScalarPos(u8, headers, start, '"') orelse return null;
        return headers[start..end];
    }
    return null;
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

const testing = std.testing;

test "detectVideoExt splits mp4/mov by brand and finds webm" {
    try testing.expectEqualStrings("webm", detectVideoExt(&[_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x02 }).?);
    try testing.expectEqualStrings("mov", detectVideoExt("\x00\x00\x00\x14ftypqt  ").?);
    try testing.expectEqualStrings("mp4", detectVideoExt("\x00\x00\x00\x18ftypisom").?);
    try testing.expect(detectVideoExt("\x89PNG\r\n\x1a\n") == null);
}

test "parseRange clamps to the file and to one window" {
    // open-ended within a small file → whole file
    try testing.expectEqual(Range{ .start = 0, .end = 999 }, parseRange("bytes=0-", 1000).?);
    // explicit, suffix, and mid ranges
    try testing.expectEqual(Range{ .start = 500, .end = 999 }, parseRange("bytes=500-999", 1000).?);
    try testing.expectEqual(Range{ .start = 800, .end = 999 }, parseRange("bytes=-200", 1000).?);
    // window cap: an open-ended range over a big file is bounded to range_window
    try testing.expectEqual(Range{ .start = 0, .end = range_window - 1 }, parseRange("bytes=0-", 64 << 20).?);
    // unsatisfiable / malformed
    try testing.expect(parseRange("bytes=2000-", 1000) == null);
    try testing.expect(parseRange("0-100", 1000) == null);
    try testing.expect(parseRange("bytes=abc", 1000) == null);
}
