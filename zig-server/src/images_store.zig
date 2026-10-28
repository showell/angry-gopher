//! images_store: the per-user Images transcript, storage half.
//! Every message-with-images a viewer can see (across all their
//! convs/sessions) collected into ONE forward-chronological file (oldest first,
//! new entries append at the bottom):
//!
//!   {chat_root}/users/<uid>/images.md
//!
//! Each entry follows the chat-transcript text pattern (blocks joined by
//! `images_sep`), human-readable:
//!
//!   Sent by apoorva at 2026-05-29T01:56:58Z, source MSG_general1_5 in 1_2:
//!   <img src="..." alt="...">
//!
//! Leaf module: storage + the shared imagesSSEEvent encoder + tag extraction, so
//! BOTH images.zig (the page backlog) and chat_store.zig (the live fanout) share
//! one encoder/format with no UI-layer dependency.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");
const disk = @import("webbox").store;
const markdown_media = @import("chat_markdown").media;

/// images_sep joins entries on disk (blank line, 13 hyphens, blank line).
pub const images_sep = "\n\n-------------\n\n";

// No lock: images.md is read and appended only by handlers, one at a time (the
// host's turn, zig-metal-unikernel HOST.md).

/// ImagesEntry is one decoded/encoded block. `at` is the RFC3339 string as
/// stored — the read+wire path needs no parsed timestamp, so the string suffices.
pub const ImagesEntry = struct {
    source_id: []const u8,
    from: []const u8,
    conv: []const u8,
    at: []const u8,
    images: []const []const u8,
};

fn userImagesPath(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ store.chat_root, "users", uid, "images.md" });
}

/// formatImagesEntry serializes an entry to its on-disk text form (no leading or
/// trailing separator — the caller joins with images_sep).
pub fn formatImagesEntry(alloc: Alloc, e: ImagesEntry) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "Sent by {s} at {s}, source MSG_{s} in {s}:", .{ e.from, e.at, e.source_id, e.conv });
    for (e.images) |tag| {
        try b.append(alloc, '\n');
        // **A TAG IS ONE LINE** (metal-vmm QUEUE 185): a newline inside one
        // could carry `images_sep` and a header, planting a forged entry in
        // every member's images.md. In a tag it is whitespace, as a space is.
        for (tag) |c| try b.append(alloc, if (c == '\n' or c == '\r') ' ' else c);
    }
    return b.toOwnedSlice(alloc);
}

/// parseImagesFile splits an images.md into entries in on-disk (chronological)
/// order, parsing the header line by hand
/// at (\S+), source MSG_(\S+) in (\S+):$`). Malformed blocks skip.
pub fn parseImagesFile(alloc: Alloc, text: []const u8) ![]ImagesEntry {
    var out: std.ArrayList(ImagesEntry) = .empty;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return out.toOwnedSlice(alloc);

    var it = std.mem.splitSequence(u8, text, images_sep);
    while (it.next()) |raw| {
        const block = std.mem.trim(u8, raw, " \t\r\n");
        if (block.len == 0) continue;
        const nl = std.mem.indexOfScalar(u8, block, '\n') orelse block.len;
        const header = block[0..nl];
        const e = parseHeader(header) orelse continue;
        const body = if (nl < block.len) block[nl + 1 ..] else "";
        out.append(alloc, .{
            .source_id = e.source_id,
            .from = e.from,
            .conv = e.conv,
            .at = e.at,
            .images = try extractImageTags(alloc, body),
        }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc);
}

/// Header is one transcript entry's parsed metadata line. Shared with code_store
/// (the Images and Code feeds use the identical `Sent by … at … source MSG_… in …:`
/// header), so parseHeader lives here as the single parser.
pub const Header = struct { from: []const u8, at: []const u8, source_id: []const u8, conv: []const u8 };

pub fn parseHeader(line: []const u8) ?Header {
    if (!std.mem.startsWith(u8, line, "Sent by ") or !std.mem.endsWith(u8, line, ":")) return null;
    const inner = line["Sent by ".len .. line.len - 1]; // strip prefix + trailing ':'
    const sep = ", source MSG_";
    const si = std.mem.indexOf(u8, inner, sep) orelse return null;
    const left = inner[0..si]; // "<from> at <at>"
    const right = inner[si + sep.len ..]; // "<source_id> in <conv>"
    const at_sep = std.mem.lastIndexOf(u8, left, " at ") orelse return null;
    const in_sep = std.mem.indexOf(u8, right, " in ") orelse return null;
    return .{
        .from = left[0..at_sep],
        .at = left[at_sep + " at ".len ..],
        .source_id = right[0..in_sep],
        .conv = right[in_sep + " in ".len ..],
    };
}

/// appendImagesEntry writes one entry to a user's images.md, prefixed by the
/// separator when the file is non-empty.
pub fn appendImagesEntry(io: Io, alloc: Alloc, uid: []const u8, e: ImagesEntry) !void {
    const path = try userImagesPath(alloc, uid);
    const entry = try formatImagesEntry(alloc, e);

    // The read only decides whether a separator is needed — the write below
    // appends rather than replacing, so a failed read cost a separator and ran
    // two entries together rather than losing any. Still worth telling apart.
    const existing = try disk.readOrEmpty(io, alloc, path, .unlimited);
    const bytes = if (existing.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ images_sep, entry })
    else
        entry;

    _ = try disk.append(io, alloc, path, bytes);
}

/// readImagesForUser returns a user's image entries in chronological order. A
/// missing file → empty.
pub fn readImagesForUser(io: Io, alloc: Alloc, uid: []const u8) ![]ImagesEntry {
    const path = try userImagesPath(alloc, uid);
    const data = (try disk.readOrNull(io, alloc, path, .unlimited)) orelse return &.{};
    return parseImagesFile(alloc, data);
}

/// extractImageTags returns every `<img\s[^>]*>` span (case-insensitive, spans
/// newlines) in `s`. Note: the `\s` (whitespace REQUIRED
/// after "img") differs from recent's `\b` variant — kept faithful to each.
pub fn extractImageTags(alloc: Alloc, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 4 < s.len and std.ascii.eqlIgnoreCase(s[i .. i + 4], "<img") and isSpace(s[i + 4])) {
            if (std.mem.indexOfScalarPos(u8, s, i + 4, '>')) |gt| {
                try out.append(alloc, s[i .. gt + 1]);
                i = gt + 1;
                continue;
            }
        }
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

/// splitMsgID splits "<sid>_<n>" at the LAST underscore. Returns the sid (or null
/// when there's no underscore past index 0).
pub fn splitMsgID(msg_id: []const u8) ?[]const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, msg_id, '_') orelse return null;
    if (cut == 0) return null;
    return msg_id[0..cut];
}

/// imagesSourceURL is the deep link to the source-message thread (the meta-row
/// link). `base_url` is the conv's URL root (/chat/c/<key> or /channel/<name>);
/// appends /<sid>#msg-<source_id>, or just base_url when the id can't split.
pub fn imagesSourceURL(alloc: Alloc, base_url: []const u8, source_id: []const u8) ![]const u8 {
    const sid = splitMsgID(source_id) orelse return base_url;
    return std.fmt.allocPrint(alloc, "{s}/{s}#msg-{s}", .{ base_url, sid, source_id });
}

/// encodeImagesEvent writes one imagesSSEEvent JSON object into `j` (field order:
/// source_id, from, conv, at, images, source_url; no fields omitted). Shared by
/// the page backlog and the live fanout so both emit one shape.
///
/// **NO STORED TAG REACHES THE PAGE AS WRITTEN**: the tags are spans of a
/// member's raw markdown, and images.js parses them as HTML into the live page.
/// Each is rebuilt here by markdown_media.safeImgAt (its attribute allowlist,
/// a same-origin src), the renderer's own rule; one it can't rebuild is dropped.
/// Here, at the one encoder, so entries already on disk are rebuilt too.
pub fn encodeImagesEvent(j: *std.ArrayList(u8), alloc: Alloc, e: ImagesEntry, source_url: []const u8) !void {
    try j.print(alloc, "{{\"source_id\":{f},\"from\":{f},\"conv\":{f},\"at\":{f},\"images\":[", .{
        std.json.fmt(e.source_id, .{}), std.json.fmt(e.from, .{}),
        std.json.fmt(e.conv, .{}),      std.json.fmt(e.at, .{}),
    });
    var first = true;
    for (e.images) |tag| {
        const safe = markdown_media.safeImgAt(alloc, tag, 0) orelse continue;
        if (!first) try j.append(alloc, ',');
        first = false;
        try j.print(alloc, "{f}", .{std.json.fmt(safe.html, .{})});
    }
    try j.print(alloc, "],\"source_url\":{f}}}", .{std.json.fmt(source_url, .{})});
}

test "encodeImagesEvent: a stored tag is rebuilt by the renderer's rule, a hostile one dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e: ImagesEntry = .{ .source_id = "t_1", .from = "ann", .conv = "1_2", .at = "2026-10-27T00:00:00Z", .images = &.{
        "<img src=x onerror=\"alert(1)\">",
        "<img src=\"/up/a.png\" width=\"40\" onload=\"alert(2)\">",
        "<img src=\"https://evil.example/t.png\">",
    } };
    var j: std.ArrayList(u8) = .empty;
    try encodeImagesEvent(&j, a, e, "/chat/c/1_2/t#msg-t_1");
    try std.testing.expect(std.mem.find(u8, j.items, "onerror") == null);
    try std.testing.expect(std.mem.find(u8, j.items, "onload") == null);
    try std.testing.expect(std.mem.find(u8, j.items, "evil.example") == null);
    try std.testing.expect(std.mem.find(u8, j.items, "/up/a.png") != null);
    try std.testing.expect(std.mem.find(u8, j.items, "width=\\\"40\\\"") != null);
}

test "images.md: a tag carrying the separator and a header plants no entry of its own (metal-vmm QUEUE 185)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forged = "<img src=\"/x.png\" alt=\"" ++ images_sep ++ "Sent by mallory at 2026-01-01T00:00:00Z, source MSG_fake in 9_9:\n<img src=\"/evil.png\">\">";
    const real: ImagesEntry = .{ .source_id = "t_1", .from = "ann", .conv = "1_2", .at = "2026-10-13T00:00:00Z", .images = &.{forged} };
    const text = try std.mem.concat(a, u8, &.{ try formatImagesEntry(a, real), images_sep, try formatImagesEntry(a, real) });
    const got = try parseImagesFile(a, text);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    for (got) |e| {
        try std.testing.expectEqualStrings("ann", e.from);
        try std.testing.expectEqualStrings("t_1", e.source_id);
    }
}
