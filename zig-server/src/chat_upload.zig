//! chat_upload: chat image uploads.
//!   POST <conv-base>/<sid>/upload          store one image, return its URL
//!   GET  <conv-base>/<sid>/uploads/<file>  serve a stored image
//! Uploads land in the session's sidecar dir (sessions/<sid>.uploads/) under a
//! random unguessable name whose extension is derived from the SNIFFED magic
//! bytes (never the client's filename). Both DMs and channels route here; the
//! conv-base + sid + dir are supplied by the caller (chat.topicRoute), so this
//! module is shape-agnostic.
//!
//! Limits: a 10 MiB per-image cap AND the per-user lifetime quota.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const edge = @import("edge.zig");
const users = @import("users.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// maxChatUploadBytes caps a single uploaded image.
const max_upload_bytes = 10 << 20; // 10 MiB

// ── write path (POST <base>/<sid>/upload) ─────────────────────────────────────

/// handleUpload accepts one multipart image upload, stores it in the session's
/// uploads sidecar under a random name (extension from sniffed magic bytes), and
/// returns {url, name, width, height} JSON. width/height are 0 (we don't decode
/// dimensions — the client omits the attrs then, per its BROWSER_WORKAROUND).
pub fn handleUpload(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_dir: []const u8, base: []const u8, sid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    // Read the Content-Type (for the multipart boundary) BEFORE the body — both
    // because reading the body advances the reader past received_head (after
    // which iterateHeaders asserts, the /send gotcha) AND because the body read
    // calls head.invalidateStrings(), which clobbers the header string memory.
    // So the boundary MUST be copied out before readLimitedBody runs.
    const ct = reqHeader(req, "content-type") orelse return edge.reject(req, .malformed_multipart, "no file\n");
    const boundary_raw = multipartBoundary(ct) orelse return edge.reject(req, .malformed_multipart, "no file\n");
    const boundary = try alloc.dupe(u8, boundary_raw);

    const body = (try http.readLimitedBody(req, alloc, max_upload_bytes + (1 << 20))) orelse return;
    const part = parseMultipartFile(alloc, body, boundary) orelse
        return edge.reject(req, .malformed_multipart, "no file\n");
    if (part.data.len > max_upload_bytes) {
        return edge.reject(req, .body_too_large, "Image too large — the limit is 10 MB.\n");
    }
    const ext = detectImageExt(part.data) orelse
        return req.respond("unsupported image type (png, jpeg, gif, webp only)\n", .{ .status = .unsupported_media_type });

    // Lifetime per-user quota — atomic add-if-under-cap.
    if (!users.reserveUploadBytes(io, alloc, uid, @intCast(part.data.len))) {
        const msg = try std.fmt.allocPrint(alloc, "Upload limit reached — you've used your {d} GB image allowance.\n", .{users.max_upload_lifetime_bytes >> 30});
        return req.respond(msg, .{ .status = .forbidden });
    }

    const token = randHex16(io, alloc) catch return req.respond("token\n", .{ .status = .internal_server_error });
    const name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ token, ext });
    const dir = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid}) });
    Io.Dir.cwd().createDirPath(io, dir) catch return req.respond("mkdir\n", .{ .status = .internal_server_error });
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = part.data }) catch
        return req.respond("write\n", .{ .status = .internal_server_error });

    const out = try std.fmt.allocPrint(alloc, "{{\"url\":\"{s}/{s}/uploads/{s}\",\"name\":{f},\"width\":0,\"height\":0}}", .{
        base, sid, name, std.json.fmt(part.filename, .{}),
    });
    try req.respond(out, .{ .extra_headers = &.{http.json_ct} });
}

// ── serve path (GET <base>/<sid>/uploads/<file>) ──────────────────────────────

/// serveUpload serves a stored image so the Images page's `<img src>` resolves
///. The name must be 32 hex + .(png|jpg|gif|webp);
/// content-type by extension; immutable private cache; nosniff. Path =
/// conv_dir/sessions/<sid>.uploads/<file>.
pub fn serveUpload(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, file: []const u8) !void {
    const ct = uploadContentType(file) orelse return http.notFound(req);
    const updir = try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid});
    const path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", updir, file });
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return http.notFound(req);
    try req.respond(data, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = ct },
        .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
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

/// detectImageExt sniffs the magic bytes of the four allowed image types and
/// returns our canonical extension. We sniff rather than
/// trust the client's filename / Content-Type.
fn detectImageExt(data: []const u8) ?[]const u8 {
    if (data.len >= 8 and std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "png";
    if (data.len >= 3 and std.mem.startsWith(u8, data, "\xff\xd8\xff")) return "jpg";
    if (data.len >= 6 and (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a"))) return "gif";
    if (data.len >= 12 and std.mem.startsWith(u8, data, "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "webp";
    return null;
}

fn extMime(ext: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ext, "png")) return "image/png";
    if (std.mem.eql(u8, ext, "jpg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, "gif")) return "image/gif";
    if (std.mem.eql(u8, ext, "webp")) return "image/webp";
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

/// reqHeader returns a request header value (case-insensitive), or null.
fn reqHeader(req: *Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}
