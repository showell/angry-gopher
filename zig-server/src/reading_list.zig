//! reading_list: the "save a chat message for later" composer + op.
//!
//! A save appends one markdown block to the saver's fixed-slug `reading-list`
//! doc (via docs_store). The Docs feature IS the combined view — open
//! /chat/docs/reading-list to read, annotate, or delete saved items, so this
//! feature ships no view of its own. This module owns two things the rest of the
//! system shouldn't duplicate: the durable on-disk BLOCK FORMAT of a saved entry,
//! and the unambiguous JUMP-BACK URL.
//!
//! Why the URL is built here and not via /chat/msg/<id>: that lookup endpoint
//! re-derives the conversation from the bare id by scanning, and a topic slug
//! is only conv-LOCAL (1_2 and 1_3 can both hold a topic named 2026-05-28), so
//! it resolves to the FIRST match. At save time we know the conv unambiguously,
//! so we freeze the fully-qualified location — the whole point of a reading list
//! that spans conversations.
//!
//! The saved body is wrapped in a `~~~ quote` fence (same inert, quote-styled
//! block quote-reply uses): shown literally by default (no live img/markdown),
//! and the user can un-fence it at their own risk. The fence length adapts to the
//! body so an inner `~~~` can't close it early — mirrors chat.js pickQuoteFence.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_fanout = @import("chat_fanout.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const disk = @import("webbox").store;
const docs_store = @import("docs_store.zig");
const mem_meter = @import("webbox").mem_meter;

/// reading_list_slug is the fixed doc every save appends to. Valid per
/// docs_store.validDocSlug; titleFromSlug renders it "Reading list" in the
/// sidebar.
pub const reading_list_slug = "reading-list";

// ── read-back: parse saved locations out of a reading-list doc ────────────────

/// Ref is one saved message's location, recovered from a jump-back URL. The
/// bytes alias the doc text they were parsed from — copy them out if they must
/// outlive it.
pub const Ref = struct { conv: []const u8, sid: []const u8, id: []const u8 };

/// parseRefs extracts every saved location from a reading-list doc by scanning
/// for the jump URLs composeEntry emits — /chat/c/<conv>/<sid>#msg-<id> and
/// /channel/<name>/<sid>#msg-<id>. The user owns this doc and edits it freely, so
/// this is deliberately lenient: a malformed/partial URL is skipped, never an
/// error. The conv segment is returned verbatim (it equals the conv key for both
/// DMs and channels). Order is by-prefix then by-position, not strict document
/// order — fine, callers treat the result as a set.
pub fn parseRefs(alloc: Alloc, text: []const u8) ![]Ref {
    var out: std.ArrayList(Ref) = .empty;
    for ([_][]const u8{ "/chat/c/", "/channel/" }) |prefix| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, prefix)) |p| {
            i = p + prefix.len;
            if (parseRefAt(text, i)) |ref| try out.append(alloc, ref);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// parseRefAt reads `<conv>/<sid>#msg-<id>` starting just past a matched URL
/// prefix; null on any deviation from that exact shape.
fn parseRefAt(text: []const u8, start: usize) ?Ref {
    var i = start;
    const conv_start = i;
    while (i < text.len and isPathSeg(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '/' or i == conv_start) return null;
    const conv = text[conv_start..i];
    i += 1; // past '/'
    const sid_start = i;
    while (i < text.len and isPathSeg(text[i])) : (i += 1) {}
    if (i == sid_start) return null;
    const sid = text[sid_start..i];
    const anchor = "#msg-";
    if (!std.mem.startsWith(u8, text[i..], anchor)) return null;
    i += anchor.len;
    const id_start = i;
    while (i < text.len and isIdChar(text[i])) : (i += 1) {}
    const id = text[id_start..i];
    if (!chat_paths.validMsgRefID(id)) return null;
    return .{ .conv = conv, .sid = sid, .id = id };
}

/// isPathSeg: a char that can appear in a conv/sid path segment (stops at '/',
/// '#', ')', whitespace, quotes — the URL/markdown delimiters).
fn isPathSeg(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
}

fn isIdChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_';
}

const testing = std.testing;
const roots = @import("roots.zig");

test "parseRefs: recovers DM + channel locations from jump URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two composed entries, a DM and a channel, as they'd sit in the doc.
    const doc =
        \\### read later
        \\
        \\apoorva · Jun 16 · [↩ open in chat](/chat/c/1_2/2026-05-28#msg-2026-05-28_5)
        \\
        \\### follow up
        \\
        \\Steve · Jun 22 · [↩ open in chat](/channel/General/general1#msg-general1_3)
        \\
    ;
    const refs = try parseRefs(a, doc);
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("1_2", refs[0].conv);
    try testing.expectEqualStrings("2026-05-28", refs[0].sid);
    try testing.expectEqualStrings("2026-05-28_5", refs[0].id);
    try testing.expectEqualStrings("General", refs[1].conv);
    try testing.expectEqualStrings("general1", refs[1].sid);
    try testing.expectEqualStrings("general1_3", refs[1].id);
}

test "parseRefs: lenient — skips malformed/partial URLs, empty doc → none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try parseRefs(a, "")).len);
    // a hand-mangled doc: no anchor, bad id (no digits), truncated — all skipped,
    // but the one intact URL survives.
    const doc =
        \\/chat/c/1_2/2026-05-28           (no anchor)
        \\/chat/c/1_2/2026-05-28#msg-nodigits
        \\/channel/General/                (truncated)
        \\[ok](/chat/c/1_2/yo#msg-yo_9)
    ;
    const refs = try parseRefs(a, doc);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("yo_9", refs[0].id);
}

// Pins the doc's mtime so cache hit/miss is deterministic, not a wall-clock race.
