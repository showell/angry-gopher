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
const markdown_media = @import("markdown_media.zig");

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
