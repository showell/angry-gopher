//! chat_upload: chat image AND screencast uploads.
//!   POST <conv-base>/<sid>/upload          store one image/video, return its URL
//!   GET  <conv-base>/<sid>/uploads/<file>  serve a stored image/video
//! Uploads land in the topic's sidecar dir (sessions/<sid>.uploads/) under a
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
const limits = @import("limits.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const edge = @import("webbox").edge;
const users = @import("users.zig");
const disk = @import("webbox").store;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// max_any_upload bounds the body read before the kind is known (sniffing needs
/// the bytes in hand): the largest per-file cap across kinds, plus multipart
/// slack. The per-kind caps themselves live on UploadKind.cap().
const max_any_upload = limits.body.upload_any;

/// **THE LINE BETWEEN HELD-WHOLE AND STREAMED** (QUEUE.md item 105). A plain GET
/// of a file up to this is read whole — the read zig-metal-unikernel's page cache keeps
/// (item 102), so a kept picture comes from memory — and a bigger one is
/// streamed. **zig-metal-unikernel's page cache takes its default `largest` from this
/// constant** (`probe/gopher.zig`), so "small enough to cache" and "small enough
/// to hold whole" are one number, in one place.
pub const whole_read_max = 4 << 20; // 4 MiB

/// How much is read and written at a time when a file is streamed, so the
/// request heap holds a piece, not the file.
const stream_piece = 256 << 10; // 256 KiB

// ── write path (POST <base>/<sid>/upload) ─────────────────────────────────────

/// handleUpload accepts one multipart image/video upload, stores it in the
/// topic's uploads sidecar under a random name (extension from sniffed magic
/// bytes), and returns {url, name, kind, width, height} JSON. `kind` is "image"
/// or "video" so the client inserts the right tag; width/height are 0 (we don't
/// decode dimensions — the client omits the attrs then, per its BROWSER_WORKAROUND).
pub fn handleUpload(
    req: *Request,
    io: Io,
    alloc: Alloc,
    uid: []const u8,
    conv_dir: []const u8,
    base: []const u8,
    sid: []const u8,
) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);

    // Read the Content-Type (for the multipart boundary) BEFORE the body: reading
    // the body advances the reader past received_head (after which iterateHeaders
    // asserts, the /send gotcha) and invalidates the head strings. http.header
    // owns its result, so `ct` (and the boundary sliced from it) survive the body read.
    const ct = (try http.header(
        req,
        alloc,
        "content-type",
    )) orelse return edge.reject(
        req,
        .malformed_multipart,
        "no file\n",
    );
    const boundary = multipartBoundary(ct) orelse return edge.reject(
        req,
        .malformed_multipart,
        "no file\n",
    );

    const body = (try http.readLimitedBody(
        req,
        alloc,
        max_any_upload,
    )) orelse return;
    const part = parseMultipartFile(body, boundary) orelse
        return edge.reject(
            req,
            .malformed_multipart,
            "no file\n",
        );

    // Sniff the kind FIRST — it carries the per-file cap and the user-facing noun.
    const sniff = detectUpload(part.data) orelse
        return req.respond(
            "unsupported file type (images: png, jpeg, gif, webp; video: mp4, webm, mov)\n",
            .{ .status = .unsupported_media_type },
        );
    if (part.data.len > sniff.kind.cap()) {
        const msg = try std.fmt.allocPrint(
            alloc,
            "{s} too large — the limit is {d} MB.\n",
            .{ sniff.kind.noun(), sniff.kind.cap() >> 20 },
        );
        return edge.reject(
            req,
            .body_too_large,
            msg,
        );
    }

    // Lifetime per-user quota — atomic add-if-under-cap. Images and screencasts
    // share the one allowance.
    if (!try users.reserveUploadBytes(
        io,
        alloc,
        uid,
        @intCast(part.data.len),
    )) {
        const msg = try std.fmt.allocPrint(
            alloc,
            "Upload limit reached — you've used your {d} GB upload allowance.\n",
            .{users.max_upload_lifetime_bytes >> 30},
        );
        return req.respond(msg, .{ .status = .forbidden });
    }

    // **THE ALLOWANCE IS SPENT ON A FILE THAT IS THERE** (metal-vmm QUEUE
    // 172): one that cannot be stored gives its bytes back, and its error goes
    // on to the host's log (it was a 500 that said "write", unlogged, with the
    // bytes spent for good).
    const name = storeUpload(
        io,
        alloc,
        conv_dir,
        sid,
        sniff.ext,
        part.data,
    ) catch |e| {
        _ = try users.reserveUploadBytes(
            io,
            alloc,
            uid,
            -@as(i64, @intCast(part.data.len)),
        );
        return e;
    };

    const out = try std.fmt.allocPrint(alloc, "{{\"url\":\"{s}/{s}/uploads/{s}\",\"name\":{f},\"kind\":\"{s}\",\"width\":0,\"height\":0}}", .{
        base,                 sid, name,
        std.json.fmt(
            try displayName(alloc, part.filename),
            .{},
        ),
        @tagName(sniff.kind),
    });
    try req.respond(out, .{ .extra_headers = &.{http.json_ct} });
}

/// **THE CLIENT'S NAME, AS TEXT** (metal-vmm QUEUE 185): a name that is not
/// UTF-8 came back in the JSON as an array of numbers. Each sequence that
/// does not decode is replaced with U+FFFD.
fn displayName(alloc: Alloc, raw: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch 0;
        if (n != 0 and i + n <= raw.len and std.meta.isError(std.unicode.utf8Decode(raw[i..][0..n])) == false) {
            try out.appendSlice(alloc, raw[i..][0..n]);
            i += n;
        } else {
            try out.appendSlice(alloc, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The upload written under its topic, by a fresh name.
fn storeUpload(
    io: Io,
    alloc: Alloc,
    conv_dir: []const u8,
    sid: []const u8,
    ext: []const u8,
    data: []const u8,
) ![]const u8 {
    const token = try randHex16(io, alloc);
    const name = try std.fmt.allocPrint(
        alloc,
        "{s}.{s}",
        .{ token, ext },
    );
    const dir = try std.fs.path.join(alloc, &.{
        conv_dir,
        "sessions",
        try std.fmt.allocPrint(
            alloc,
            "{s}.uploads",
            .{sid},
        ),
    });
    try disk.makeDir(
        io,
        alloc,
        dir,
    );
    try disk.write(
        io,
        alloc,
        try std.fs.path.join(alloc, &.{ dir, name }),
        data,
        .{},
    );
    return name;
}

// ── serve path (GET <base>/<sid>/uploads/<file>) ──────────────────────────────

/// The part of an upload the Roc chose to serve (Host.serve_upload!, metal-vmm
/// QUEUE 291): the whole file, the bytes `first` to `last`, or a range it
/// cannot serve.
pub const Served = union(enum) {
    whole,
    range: struct { first: u64, last: u64 },
    unsatisfiable,
};

/// **AN UPLOAD SERVED**, where the Roc decided it (its name, type, the
/// viewer's right to it and its range: roc-webbox chat/main.roc
/// `serve_upload!`, metal-vmm QUEUE 291): the file at `path`, `size` bytes by
/// the Roc's stat, typed `ct`, immutable private cache, nosniff,
/// `accept-ranges` always. A range is one window, read positionally, so only
/// that slice is in RAM; a plain GET (images, direct download) gets the whole
/// file. `.gone` when the file went since the stat: nothing was answered.
pub fn serveStored(
    req: *Request,
    io: Io,
    alloc: Alloc,
    path: []const u8,
    size: u64,
    ct: []const u8,
    part: Served,
) !enum { gone, served } {
    switch (part) {
        .unsatisfiable => {
            const cr = try std.fmt.allocPrint(
                alloc,
                "bytes */{d}",
                .{size},
            );
            try req.respond("", .{ .status = .range_not_satisfiable, .extra_headers = &.{
                .{ .name = "content-range", .value = cr },
                .{ .name = "accept-ranges", .value = "bytes" },
            } });
            return .served;
        },
        .range => |r| {
            const len: usize = @intCast(r.last - r.first + 1);
            const buf = try alloc.alloc(u8, len);
            const n = disk.readAt(
                io,
                alloc,
                path,
                r.first,
                buf,
            ) catch |e| switch (e) {
                error.FileNotFound => return .gone, // gone since its stat
                else => return e,
            };
            // An upload is never rewritten, so a read shorter than its stat
            // promised is a fault, not a range to answer from.
            if (n != len) return error.UploadShorterThanItsStat;
            const cr = try std.fmt.allocPrint(
                alloc,
                "bytes {d}-{d}/{d}",
                .{
                    r.first,
                    r.last,
                    size,
                },
            );
            // The range is one window, so it is read and sent whole with a
            // content-length (the plain GET below is the one that was
            // unbounded — item 105).
            try req.respond(buf[0..n], .{ .status = .partial_content, .extra_headers = &.{
                .{ .name = "content-type", .value = ct },
                .{ .name = "content-range", .value = cr },
                .{ .name = "accept-ranges", .value = "bytes" },
                .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            } });
            return .served;
        },
        .whole => {},
    }

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = ct },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    // **A FILE SMALL ENOUGH TO CACHE IS READ WHOLE; A BIGGER ONE IS STREAMED**
    // (QUEUE.md item 105, composing with item 102). A whole read (offset 0, the
    // buffer holding all of it) is the read zig-metal-unikernel's page cache keeps, so
    // a kept picture is served from memory; a file past the cap the cache keeps
    // — which is `whole_read_max` — would both fill that heap buffer and not be
    // cacheable, so it is streamed in `stream_piece` chunks: the heap holds a
    // piece, not the file (a 100 MiB screencast downloaded whole was 100 MiB of
    // request heap before this).
    if (size <= whole_read_max) {
        const data = try alloc.alloc(u8, @intCast(size));
        const n = disk.readAt(
            io,
            alloc,
            path,
            0,
            data,
        ) catch |e| switch (e) {
            error.FileNotFound => return .gone, // gone since its stat
            else => return e,
        };
        // As for a range: a file shorter than its stat is a fault, never
        // served as the whole file (metal-vmm QUEUE 172).
        if (n != data.len) return error.UploadShorterThanItsStat;
        try req.respond(data, .{ .extra_headers = &headers });
        return .served;
    }
    try streamFile(
        req,
        io,
        alloc,
        path,
        size,
        &headers,
    );
    return .served;
}

/// Streams `len` bytes of `path` from the start into the response, `stream_piece`
/// at a time, so the request heap holds a piece, not the file.
///
/// **CHUNKED, NOT CONTENT-LENGTH.** Once the first byte is out the status cannot
/// change, so a read that fails partway cannot become a 404 — it just ends the
/// stream (the same bargain admin_backup.zig makes). A content-length header
/// would then be a promise broken by a short body — std's `end()` asserts every
/// promised byte was written — so a device fault mid-serve would panic the
/// machine. Chunked has no such promise: a truncated stream is cut with no
/// terminator, which the client reads as the error it is, and the error goes
/// on to the host's log. A HEAD gets the
/// headers and no body, and reads nothing.
fn streamFile(
    req: *Request,
    io: Io,
    alloc: Alloc,
    path: []const u8,
    len: u64,
    headers: []const std.http.Header,
) !void {
    var hbuf: [1024]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = headers },
    }) catch return;
    if (req.head.method != .HEAD) {
        const buf = try alloc.alloc(u8, @intCast(@min(len, stream_piece)));
        var at: u64 = 0;
        while (at < len) {
            const want: usize = @intCast(@min(@as(u64, buf.len), len - at));
            // The headers are out: a read that fails, or a file shorter than
            // its stat, cuts the stream with no last chunk, and its error
            // goes to the host's log (metal-vmm QUEUE 172: `end()` here wrote
            // the last chunk, a truncated file delivered as whole).
            const n = try disk.readAt(
                io,
                alloc,
                path,
                at,
                buf[0..want],
            );
            if (n == 0) return error.UploadShorterThanItsStat;
            body.writer.writeAll(buf[0..n]) catch return; // the client is gone
            at += n;
        }
    }
    body.end() catch {};
}

// ── helpers ───────────────────────────────────────────────────────────────────

pub const UploadKind = enum {
    image,
    video,

    /// per-file upload cap for this kind (the shared lifetime quota is separate).
    fn cap(k: UploadKind) usize {
        return switch (k) {
            .image => limits.body.upload_image,
            .video => limits.body.upload_video,
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
///
/// **ITS KIND IS THE TABLE'S** (the review of 157): an extension the sniffers
/// find and `accepted` does not list is refused, never stored to be served
/// as nothing; every row's sample sniffs as that row (a test).
fn detectUpload(data: []const u8) ?Sniffed {
    const ext = detectImageExt(data) orelse detectVideoExt(data) orelse return null;
    for (accepted) |t| if (std.mem.eql(
        u8,
        t.ext,
        ext,
    )) return .{ .ext = t.ext, .kind = t.kind };
    return null;
}

fn detectImageExt(data: []const u8) ?[]const u8 {
    if (data.len >= 8 and std.mem.startsWith(
        u8,
        data,
        "\x89PNG\r\n\x1a\n",
    )) return "png";
    if (data.len >= 3 and std.mem.startsWith(
        u8,
        data,
        "\xff\xd8\xff",
    )) return "jpg";
    if (data.len >= 6 and (std.mem.startsWith(
        u8,
        data,
        "GIF87a",
    ) or std.mem.startsWith(
        u8,
        data,
        "GIF89a",
    ))) return "gif";
    if (data.len >= 12 and std.mem.startsWith(
        u8,
        data,
        "RIFF",
    ) and std.mem.eql(
        u8,
        data[8..12],
        "WEBP",
    )) return "webp";
    return null;
}

/// detectVideoExt sniffs the three screencast containers. WebM/Matroska open
/// with the EBML magic; mp4 and mov are both ISO-BMFF with an "ftyp" box at
/// offset 4 — the major brand at offset 8 ("qt  " = QuickTime) splits them.
fn detectVideoExt(data: []const u8) ?[]const u8 {
    if (data.len >= 4 and std.mem.eql(
        u8,
        data[0..4],
        &[_]u8{
            0x1A,
            0x45,
            0xDF,
            0xA3,
        },
    )) return "webm";
    if (data.len >= 12 and std.mem.eql(
        u8,
        data[4..8],
        "ftyp",
    )) {
        return if (std.mem.eql(
            u8,
            data[8..12],
            "qt  ",
        )) "mov" else "mp4";
    }
    return null;
}

/// **EVERY TYPE AN UPLOAD MAY BE, ONCE** (metal-vmm QUEUE 157(d)): what a
/// stored file is served as, and the list the page hands the client for its
/// file picker (`accept`), where chat_compose.js kept a copy that "must
/// match". The sniffers above decide what a file is; this names it.
/// Each row also names its kind (its cap) and the least a file of it begins
/// with, so a test holds the sniffers to the table.
pub const accepted = [_]struct {
    ext: []const u8,
    mime: []const u8,
    kind: UploadKind,
    sample: []const u8,
}{
    .{
        .ext = "png",
        .mime = "image/png",
        .kind = .image,
        .sample = "\x89PNG\r\n\x1a\n",
    },
    .{
        .ext = "jpg",
        .mime = "image/jpeg",
        .kind = .image,
        .sample = "\xff\xd8\xff\xe0",
    },
    .{
        .ext = "gif",
        .mime = "image/gif",
        .kind = .image,
        .sample = "GIF89a",
    },
    .{
        .ext = "webp",
        .mime = "image/webp",
        .kind = .image,
        .sample = "RIFF\x00\x00\x00\x00WEBP",
    },
    .{
        .ext = "mp4",
        .mime = "video/mp4",
        .kind = .video,
        .sample = "\x00\x00\x00\x18ftypisom",
    },
    .{
        .ext = "webm",
        .mime = "video/webm",
        .kind = .video,
        .sample = "\x1a\x45\xdf\xa3",
    },
    .{
        .ext = "mov",
        .mime = "video/quicktime",
        .kind = .video,
        .sample = "\x00\x00\x00\x14ftypqt  ",
    },
};

/// The accepted types as a file picker's `accept` attribute takes them.
pub const accept = blk: {
    var s: []const u8 = "";
    for (accepted, 0..) |t, i| s = s ++ (if (i == 0) "" else ",") ++ t.mime;
    break :blk s;
};

/// The per-file caps, as the page hands them to the client.
pub const image_max = limits.body.upload_image;
pub const video_max = limits.body.upload_video;

fn extMime(ext: []const u8) ?[]const u8 {
    for (accepted) |t| if (std.mem.eql(
        u8,
        t.ext,
        ext,
    )) return t.mime;
    return null;
}

/// The extension a MIME type is stored under, or null when it is not taken.
pub fn extOf(mime: []const u8) ?[]const u8 {
    for (accepted) |t| if (std.mem.eql(
        u8,
        t.mime,
        mime,
    )) return t.ext;
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
    const p = std.mem.indexOf(
        u8,
        ct,
        "boundary=",
    ) orelse return null;
    var v = ct[p + "boundary=".len ..];
    if (v.len > 0 and v[0] == '"') {
        v = v[1..];
        const e = std.mem.indexOfScalar(
            u8,
            v,
            '"',
        ) orelse return null;
        return v[0..e];
    }
    if (std.mem.indexOfScalar(
        u8,
        v,
        ';',
    )) |e| v = v[0..e];
    return std.mem.trim(
        u8,
        v,
        " \t\r\n",
    );
}

/// parseMultipartFile returns the first part whose Content-Disposition name is
/// "file" (its filename + raw bytes), or null. A focused parser for the single
/// FormData field the compose client sends — not a general multipart decoder.
fn parseMultipartFile(body: []const u8, boundary: []const u8) ?Part {
    // No allocation, so memory that runs out is never "no file" (metal-vmm
    // QUEUE 172): a boundary is at most 70 bytes (RFC 2046 §5.1.1), and one
    // longer is no multipart we read.
    var delim_buf: [2 + 70]u8 = undefined;
    const delim = std.fmt.bufPrint(
        &delim_buf,
        "--{s}",
        .{boundary},
    ) catch return null;
    var pos = std.mem.indexOf(
        u8,
        body,
        delim,
    ) orelse return null;
    while (true) {
        var i = pos + delim.len;
        if (i + 2 <= body.len and body[i] == '-' and body[i + 1] == '-') return null; // closing delimiter
        if (i + 2 <= body.len and body[i] == '\r' and body[i + 1] == '\n') i += 2;

        const hdr_rel = std.mem.indexOf(
            u8,
            body[i..],
            "\r\n\r\n",
        ) orelse return null;
        const headers = body[i .. i + hdr_rel];
        const data_start = i + hdr_rel + 4;
        // indexOfPos returns an ABSOLUTE index into body (not relative to data_start).
        const next_abs = std.mem.indexOfPos(
            u8,
            body,
            data_start,
            delim,
        ) orelse return null;
        var data_end = next_abs;
        if (data_end >= data_start + 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') data_end -= 2;

        if (attrVal(headers, "name")) |nm| {
            if (std.mem.eql(
                u8,
                nm,
                "file",
            )) {
                return .{
                    .filename = attrVal(headers, "filename") orelse "image",
                    .data = body[data_start..data_end],
                };
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
    while (std.mem.indexOfPos(
        u8,
        headers,
        i,
        attr,
    )) |p| {
        i = p + attr.len;
        if (i + 1 >= headers.len or headers[i] != '=' or headers[i + 1] != '"') continue;
        if (p > 0 and isAlpha(headers[p - 1])) continue;
        const start = i + 2;
        const end = std.mem.indexOfScalarPos(
            u8,
            headers,
            start,
            '"',
        ) orelse return null;
        return headers[start..end];
    }
    return null;
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

const testing = std.testing;

test "detectVideoExt splits mp4/mov by brand and finds webm" {
    try testing.expectEqualStrings("webm", detectVideoExt(&[_]u8{
        0x1A,
        0x45,
        0xDF,
        0xA3,
        0x01,
        0x02,
    }).?);
    try testing.expectEqualStrings("mov", detectVideoExt("\x00\x00\x00\x14ftypqt  ").?);
    try testing.expectEqualStrings("mp4", detectVideoExt("\x00\x00\x00\x18ftypisom").?);
    try testing.expect(detectVideoExt("\x89PNG\r\n\x1a\n") == null);
}

test "the sniffers: data exactly a magic's length is found, one byte less is not" {
    const cases = [_]struct { data: []const u8, ext: []const u8 }{
        .{ .data = "\x89PNG\r\n\x1a\n", .ext = "png" },
        .{ .data = "\xff\xd8\xff", .ext = "jpg" },
        .{ .data = "GIF87a", .ext = "gif" },
        .{ .data = "GIF89a", .ext = "gif" },
        .{ .data = "RIFF\x00\x00\x00\x00WEBP", .ext = "webp" },
        .{ .data = "\x1a\x45\xdf\xa3", .ext = "webm" },
        .{ .data = "\x00\x00\x00\x18ftypisom", .ext = "mp4" },
        .{ .data = "\x00\x00\x00\x14ftypqt  ", .ext = "mov" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c.ext, detectUpload(c.data).?.ext);
        try testing.expect(detectUpload(c.data[0 .. c.data.len - 1]) == null);
    }
}

test "parseMultipartFile: a part of no bytes is empty, a part of one byte is that byte" {
    const head = "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x.png\"\r\n\r\n";
    try testing.expectEqualStrings("", parseMultipartFile(head ++ "\r\n--B--\r\n", "B").?.data);
    try testing.expectEqualStrings("Z", parseMultipartFile(head ++ "Z\r\n--B--\r\n", "B").?.data);
    // Data that is itself a CRLF keeps it: only the delimiter's CRLF is trimmed.
    try testing.expectEqualStrings(
        "\r\n",
        parseMultipartFile(head ++ "\r\n\r\n--B--\r\n", "B").?.data,
    );
    // A delimiter with no CRLF before it trims nothing, at one byte or none.
    try testing.expectEqualStrings("Z", parseMultipartFile(head ++ "Z--B--", "B").?.data);
    try testing.expectEqualStrings("", parseMultipartFile(head ++ "--B--", "B").?.data);
}

test "parseMultipartFile: a delimiter at the very end of the body closes the part; a body ending inside a part has none" {
    const head = "--B\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n";
    try testing.expectEqualStrings("abc", parseMultipartFile(head ++ "abc\r\n--B", "B").?.data);
    try testing.expect(parseMultipartFile(head ++ "abc\r\n--", "B") == null);
    // Another field first, the body ending at its closing delimiter: no file.
    const other = "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhi\r\n--B";
    try testing.expect(parseMultipartFile(other, "B") == null);
    try testing.expect(parseMultipartFile(other ++ "-", "B") == null);
    try testing.expect(parseMultipartFile(other ++ "--", "B") == null);
    // A body that is the delimiter alone, and one byte short of it.
    try testing.expect(parseMultipartFile("--B", "B") == null);
    try testing.expect(parseMultipartFile("--", "B") == null);
}

test "a stream whose file ends before its length is cut, never ended as whole: no last chunk, and an error for the host's log (metal-vmm QUEUE 172)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "clip.webm",
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &@as([1000]u8, @splat('x')) });

    var reader: std.Io.Reader = .fixed("GET /u/clip.webm HTTP/1.1\r\nHost: x\r\n\r\n");
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    // Its stat said 2000 bytes; 1000 are there.
    try std.testing.expectError(error.UploadShorterThanItsStat, streamFile(
        &req,
        io,
        a,
        path,
        2000,
        &.{},
    ));
    out.writer.flush() catch {};
    try std.testing.expect(!std.mem.endsWith(
        u8,
        out.written(),
        "0\r\n\r\n",
    ));
}

test "parseMultipartFile allocates nothing: memory that runs out is never 'no file', a 400 (metal-vmm QUEUE 172)" {
    const body = "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n\r\nZ\r\n--B--\r\n";
    try std.testing.expectEqualStrings("Z", parseMultipartFile(body, "B").?.data);
}

test "an upload's name that is not UTF-8 is answered as a JSON string, what does not decode replaced (metal-vmm QUEUE 185)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try displayName(a, "caf\xe9 \xff.png");
    try std.testing.expect(std.unicode.utf8ValidateSlice(name));
    try std.testing.expectEqualStrings("caf\u{FFFD} \u{FFFD}.png", name);
    const json = try std.fmt.allocPrint(
        a,
        "{f}",
        .{std.json.fmt(name, .{})},
    );
    try std.testing.expect(json[0] == '"');
    // Valid names pass as they are.
    try std.testing.expectEqualStrings("é.png", try displayName(a, "é.png"));
}
