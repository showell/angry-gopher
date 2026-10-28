//! chat_codec: a transcript's blocks, decoded off disk and encoded onto it
//! (metal-vmm QUEUE 174: chat_store.zig split by the 1,000-line rule; the
//! format is chat_store.zig's header). Pure: bytes in, bytes or messages out,
//! and the count of blocks refused.

const std = @import("std");
const fixtures = @import("chat_fixtures_test.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const bus_mod = @import("webbox").bus;
const testing = std.testing;
const chat_store = @import("chat_store.zig");
const chat_paths = @import("chat_paths.zig");
const chat_count = @import("chat_count.zig");
const indexOf = chat_count.indexOf;
const readCount = chat_count.readCount;
const backfillSidecars = chat_count.backfillSidecars;
const countPath = chat_count.countPath;
const readTranscript = chat_paths.readTranscript;
const transcriptPath = chat_paths.transcriptPath;
const cutSeq = chat_store.cutSeq;
const CountFixture = fixtures.CountFixture;
const sep = chat_store.sep;
const dashes = chat_store.dashes;
const ChatMessage = chat_store.ChatMessage;

/// Reads that met a refused transcript block, since boot (metal-vmm QUEUE
/// 156(h)): a block with no `MSG_` id, author or date, which decoded as a
/// message of "" before. **A COUNT OF READS, NOT OF BLOCKS**: one bad block
/// is counted again by every page, stream and search build that reads it, so
/// the number grows with traffic; any number above none is the signal, and
/// /admin/host (`refusedText`) names the last one's first line.
pub var refused_blocks: usize = 0;

var refused_last_buf: [96]u8 = undefined;

var refused_last: []const u8 = "";

/// The refused blocks as /admin/host shows them.
pub fn refusedText(alloc: Alloc) ![]const u8 {
    if (refused_blocks == 0) return "none";
    return std.fmt.allocPrint(alloc, "{d}; the last began: {s}", .{ refused_blocks, refused_last });
}

/// Whether a decoded block is a message: it has an id, an author and a date
/// (the decoder and search's in-place reading ask the same).
pub fn isMessage(m: ChatMessage) bool {
    return m.id.len > 0 and m.from.len > 0 and m.at.len > 0;
}

/// A block that is not a message: counted, and its first line kept to say.
pub fn refuseBlock(piece: []const u8) void {
    refused_blocks += 1;
    const first = piece[0 .. std.mem.indexOfScalar(u8, piece, '\n') orelse piece.len];
    const n = @min(first.len, refused_last_buf.len);
    @memcpy(refused_last_buf[0..n], first[0..n]);
    refused_last = refused_last_buf[0..n];
}

/// decodeChatFile parses a whole topic file into messages. Splits on `sep`
/// (no trailing separator on disk, so one piece per message).
///
/// **TWO SKIPS, NAMED** (metal-vmm QUEUE 156(h)):
/// - an all-whitespace piece is no block, and uncounted: an append torn
///   right after its separator leaves one, as a file that begins with one
///   does;
/// - a block that is not a message (`isMessage`: no `MSG_` id, author or
///   date; an append torn inside its header is one) is refused, counted and
///   said (`refuseBlock`), where it decoded as a message of "". Never the
///   whole transcript: the next append lands after it, so a torn block is
///   not only ever the last.
pub fn decodeChatFile(alloc: Alloc, data: []const u8) ![]ChatMessage {
    var out: std.ArrayList(ChatMessage) = .empty;
    var it = std.mem.splitSequence(u8, data, sep);
    while (it.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t\r\n").len == 0) continue;
        const m = try decodeChatBlock(alloc, piece);
        if (!isMessage(m)) {
            refuseBlock(piece);
            continue;
        }
        try out.append(alloc, m);
    }
    return out.toOwnedSlice(alloc);
}

/// decodeChatBlock parses one block: a `MSG_` id line, `key: value` header lines
/// until a blank line, then the verbatim (line-unescaped) markdown body.
fn decodeChatBlock(alloc: Alloc, piece: []const u8) !ChatMessage {
    var lines: std.ArrayList([]const u8) = .empty;
    var lit = std.mem.splitScalar(u8, piece, '\n');
    while (lit.next()) |ln| try lines.append(alloc, ln);
    const ls = lines.items;

    var msg: ChatMessage = .{ .id = "", .from = "", .at = "", .markdown = "" };
    var i: usize = 0;
    if (i < ls.len and std.mem.startsWith(u8, ls[i], "MSG_")) {
        msg.id = ls[i]["MSG_".len..];
        i += 1;
    }
    while (i < ls.len) : (i += 1) {
        if (ls[i].len == 0) break; // blank line ends the header
        if (cutSeq(ls[i], ": ")) |kv| {
            if (std.mem.eql(u8, kv.before, "from")) {
                msg.from = kv.after;
            } else if (std.mem.eql(u8, kv.before, "date")) {
                msg.at = kv.after;
            } else if (std.mem.eql(u8, kv.before, "uid")) {
                msg.uid = kv.after;
            }
        }
    }

    // body = lines[i+1..] (everything after the blank), each line unescaped.
    var body: std.ArrayList(u8) = .empty;
    var j = i + 1;
    var first = true;
    while (j < ls.len) : (j += 1) {
        if (!first) try body.append(alloc, '\n');
        first = false;
        try body.appendSlice(alloc, unescapeBodyLine(ls[j]));
    }
    msg.markdown = try body.toOwnedSlice(alloc);
    return msg;
}

/// unescapeBodyLine reverses the body-line escaping: a line that is one-or-more
/// backslashes followed by exactly 13 hyphens (the `^\\+-------------$` shape)
/// loses one leading backslash. Everything else passes through.
pub fn unescapeBodyLine(line: []const u8) []const u8 {
    var k: usize = 0;
    while (k < line.len and line[k] == '\\') k += 1;
    if (k >= 1 and std.mem.eql(u8, line[k..], dashes)) return line[1..];
    return line;
}

// ── write path + live fan-out ───────────

// ── the last message, for /chat/recent ────────────────────────────────────────

test "a message's author is stored as `uid:` after its date, read back, and adds only that line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const with = ChatMessage{ .id = "t_1", .from = "Steve", .at = "2026-10-25T12:00:00Z", .markdown = "hi\nthere", .uid = "1" };
    const block = try fixtures.chatStoredForm(a, 0, with);
    try testing.expectEqualStrings("MSG_t_1\nfrom: Steve\ndate: 2026-10-25T12:00:00Z\nuid: 1\n\nhi\nthere", block);
    const back = (try decodeChatFile(a, block))[0];
    try testing.expectEqualStrings("1", back.uid);
    try testing.expectEqualStrings("Steve", back.from);
    try testing.expectEqualStrings("hi\nthere", back.markdown);
    // No author known: no `uid:` line, the block as it always was.
    var without = with;
    without.uid = "";
    try testing.expectEqualStrings("MSG_t_1\nfrom: Steve\ndate: 2026-10-25T12:00:00Z\n\nhi\nthere", try fixtures.chatStoredForm(a, 0, without));
    try testing.expectEqualStrings("", (try decodeChatFile(a, try fixtures.chatStoredForm(a, 0, without)))[0].uid);
}

test "the decoder refuses a block with no id, author or date, counted; a blank piece is a torn append's and skipped (metal-vmm QUEUE 156(h))" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const good = "MSG_t_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nhello";
    const before = refused_blocks;
    inline for ([_][]const u8{
        "from: Steve\ndate: 2026-10-10T00:00:00Z\n\nno id",
        "MSG_t_2\ndate: 2026-10-10T00:00:00Z\n\nno author",
        "MSG_t_2\nfrom: Steve\n\nno date",
        "MSG_t_2\nfro", // an append torn inside its header
    }, 1..) |bad, n| {
        const msgs = try decodeChatFile(x, good ++ sep ++ bad);
        try testing.expectEqual(@as(usize, 1), msgs.len);
        try testing.expectEqual(before + n, refused_blocks);
    }
    // A blank piece (an append torn right after its separator) is no block.
    try testing.expectEqual(@as(usize, 1), (try decodeChatFile(x, good ++ sep ++ "  \n")).len);
    try testing.expectEqual(before + 4, refused_blocks);
}

test "a refused block keeps its number: a recount counts blocks, so no id is given twice; and no message is written with no author (the review of 156: the Roc's append_message! refuses one)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    // As one written before: t_2 has no author, and the sidecar is gone.
    _ = try f.send("one");
    const md = try transcriptPath(a, f.dir, "topic");
    try Io.Dir.cwd().writeFile(f.io, .{ .sub_path = md, .data = try std.fmt.allocPrint(a, "{s}{s}MSG_topic_2\nfrom: \ndate: 2026-10-10T00:00:00Z\n\nnameless{s}MSG_topic_3\nfrom: Tester\ndate: 2026-10-10T00:00:01Z\n\nthree", .{ (try readTranscript(f.io, a, f.dir, "topic")).?, sep, sep }) });
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    try testing.expectEqualStrings("topic_4", (try f.send("four")).id);
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    const dirs = [_][]const u8{f.dir};
    _ = backfillSidecars(f.io, a, &dirs);
    try testing.expectEqual(@as(usize, 4), readCount(f.io, a, f.dir, "topic").?.count);
    try testing.expectEqual(@as(usize, 3), indexOf("topic_4", "topic").?);
}
