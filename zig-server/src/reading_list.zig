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
//! re-derives the conversation from the bare id by scanning, and a session slug
//! is only conv-LOCAL (1_2 and 1_3 can both hold a session named 2026-05-28), so
//! it resolves to the FIRST match. At save time we know the conv unambiguously,
//! so we freeze the fully-qualified location — the whole point of a reading list
//! that spans conversations.
//!
//! The saved body is wrapped in a `~~~ quote` fence (same inert, quote-styled
//! block quote-reply uses): shown literally by default (no live img/markdown),
//! and the user can un-fence it at their own risk. The fence length adapts to the
//! body so an inner `~~~` can't close it early — mirrors chat.js pickQuoteFence.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");
const docs_store = @import("docs_store.zig");

/// reading_list_slug is the fixed doc every save appends to. Valid per
/// docs_store.validDocSlug; titleFromSlug renders it "Reading list" in the
/// sidebar.
pub const reading_list_slug = "reading-list";

/// max_reading_list_bytes caps the doc so a client hammering the save endpoint
/// can't grow it without bound. The bytes are the saver's own private doc, but
/// they're still ours to host. 1 MiB is thousands of entries.
pub const max_reading_list_bytes: usize = 1 << 20;

/// jumpURL is the unambiguous deep link to a saved message — the same shape
/// chatMsgLookup redirects to, but built from the conv we already know instead of
/// re-derived. DM: /chat/c/<conv>/<sid>#msg-<id>; channel: /channel/<name>/<sid>#msg-<id>.
pub fn jumpURL(alloc: Alloc, conv: []const u8, sid: []const u8, id: []const u8) ![]u8 {
    const base = try store.convKeyBaseURL(alloc, conv);
    return std.fmt.allocPrint(alloc, "{s}/{s}#msg-{s}", .{ base, sid, id });
}

/// composeEntry renders one reading-list block. Pure (no IO): the handler feeds
/// it the snapshot-as-seen (body markdown, author, display date) + the annotation
/// + the jump URL. The annotation is an H3 (so the doc skims like a checklist);
/// an empty note defaults to "read later". The single-line fields are
/// newline-stripped so a crafted POST can't break the block structure; the body
/// is left verbatim inside the fence.
pub fn composeEntry(alloc: Alloc, note: []const u8, from: []const u8, when: []const u8, url: []const u8, body: []const u8) ![]u8 {
    const note_trimmed = std.mem.trim(u8, note, " \t\r\n");
    const note_eff = if (note_trimmed.len == 0) "read later" else try oneLine(alloc, note_trimmed);
    const fence = try quoteFence(alloc, body);
    return std.fmt.allocPrint(
        alloc,
        "### {s}\n\n{s} · {s} · [↩ open in chat]({s})\n\n{s} quote\n{s}\n{s}\n\n---\n\n",
        .{ note_eff, try oneLine(alloc, from), try oneLine(alloc, when), url, fence, body, fence },
    );
}

/// save composes the entry and appends it to the saver's reading-list doc. The
/// only IO step; everything testable is in composeEntry / jumpURL above.
pub fn save(io: Io, alloc: Alloc, uid: []const u8, conv: []const u8, sid: []const u8, id: []const u8, from: []const u8, when: []const u8, body: []const u8, note: []const u8) !void {
    const url = try jumpURL(alloc, conv, sid, id);
    const entry = try composeEntry(alloc, note, from, when, url, body);
    try docs_store.appendToUserDoc(io, alloc, uid, reading_list_slug, entry, max_reading_list_bytes);
}

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
    if (!store.validMsgRefID(id)) return null;
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

/// oneLine returns a copy of s with newlines/CRs flattened to spaces — for the
/// single-line fields (note, from, when) that sit in a heading or meta line.
fn oneLine(alloc: Alloc, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    return out;
}

/// quoteFence returns a run of `~` long enough to wrap `body` safely: one longer
/// than the longest `~~~`+ run on any line of the body (min 3). Mirrors chat.js
/// pickQuoteFence so saved snapshots fence exactly like quote-reply.
fn quoteFence(alloc: Alloc, body: []const u8) ![]u8 {
    var longest: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        var run: usize = 0; // count leading '~' on this line
        while (i + run < body.len and body[i + run] == '~') : (run += 1) {}
        if (run >= 3 and run > longest) longest = run;
        while (i < body.len and body[i] != '\n') : (i += 1) {} // to line end
        if (i < body.len) i += 1; // past the '\n'
    }
    const n = @max(@as(usize, 2), longest) + 1;
    const buf = try alloc.alloc(u8, n);
    @memset(buf, '~');
    return buf;
}

const testing = std.testing;

// composeEntry/jumpURL allocate intermediates (the fence, one-lined fields) that
// production frees via the per-request arena; the tests mirror that with an arena
// rather than tracking each interior allocation.

test "composeEntry: basic block, default annotation, single-line meta" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try composeEntry(arena.allocator(), "read later", "apoorva", "Jun 16", "/chat/c/1_2/2026-05-28#msg-2026-05-28_5", "hello");
    try testing.expectEqualStrings(
        "### read later\n\napoorva · Jun 16 · [↩ open in chat](/chat/c/1_2/2026-05-28#msg-2026-05-28_5)\n\n~~~ quote\nhello\n~~~\n\n---\n\n",
        got,
    );
}

test "composeEntry: empty note falls back to 'read later'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try composeEntry(arena.allocator(), "   ", "Steve", "Jun 16", "u", "x");
    try testing.expect(std.mem.startsWith(u8, got, "### read later\n"));
}

test "composeEntry: note newlines flattened so the heading can't break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try composeEntry(arena.allocator(), "line1\nline2", "Steve", "Jun 16", "u", "x");
    try testing.expect(std.mem.startsWith(u8, got, "### line1 line2\n"));
}

test "composeEntry: fence grows past an inner ~~~ in the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "before\n~~~\ncode\n~~~\nafter";
    const got = try composeEntry(arena.allocator(), "n", "f", "w", "u", body);
    // body has a 3-tilde run, so the wrapping fence must be 4 tildes
    try testing.expect(std.mem.indexOf(u8, got, "~~~~ quote\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\n~~~~\n\n---\n\n") != null);
}

test "jumpURL: DM and channel shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/chat/c/1_2/2026-05-28#msg-2026-05-28_5", try jumpURL(a, "1_2", "2026-05-28", "2026-05-28_5"));
    try testing.expectEqualStrings("/channel/General/topic1#msg-topic1_3", try jumpURL(a, "General", "topic1", "topic1_3"));
}

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
