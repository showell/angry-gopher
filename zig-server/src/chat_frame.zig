//! chat_frame: a topic stream's SSE frames, the one place they are built.
//!
//! **A FRAME IS BUILT ONCE, THE SAME FOR EVERY VIEWER.** A message's frame is
//! made inside the turn that stores it (chat_store.appendMessage), with its
//! markdown rendered there, and published on the bus as it will go out; a
//! stream's backlog frames are made by the same function, so a message reads
//! the same live or replayed. The host's render for a kept topic stream copies
//! the blob through (chat_sse.verbatim): no parse, no markdown, no viewer,
//! on the connection's own task or in the single loop's pump. Whose message
//! it is (`mine`) is the client's to say, from `from` and the page's
//! `data-me-name`.

const std = @import("std");
const markdown = @import("markdown.zig");

const Alloc = std.mem.Allocator;

/// One message, as its frame carries it: `index` is 0-based (the SSE `id:`),
/// `at` the stored RFC3339 date, `cid` the sender's client id (empty: none).
pub const Message = struct {
    index: usize,
    from: []const u8,
    at: []const u8,
    id: []const u8,
    markdown: []const u8,
    cid: []const u8 = "",
};

/// messageFrame is one message's SSE event: `id: <index>`, then a `data:` line
/// of JSON with `html` rendered here from `markdown`. `cid` is included only
/// when non-empty (a backlog frame never has one).
pub fn messageFrame(alloc: Alloc, m: Message) ![]u8 {
    const html = try markdown.render(alloc, m.markdown);
    if (m.cid.len > 0) {
        return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f},\"cid\":{f}}}\n\n", .{
            m.index,                   m.index,
            std.json.fmt(m.from, .{}), std.json.fmt(m.at, .{}),
            std.json.fmt(html, .{}),   std.json.fmt(m.markdown, .{}),
            std.json.fmt(m.id, .{}),   std.json.fmt(m.cid, .{}),
        });
    }
    return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f}}}\n\n", .{
        m.index,                   m.index,
        std.json.fmt(m.from, .{}), std.json.fmt(m.at, .{}),
        std.json.fmt(html, .{}),   std.json.fmt(m.markdown, .{}),
        std.json.fmt(m.id, .{}),
    });
}

/// reactionFrame is a reaction's SSE event: `event: reaction`, its data the
/// sidecar's own line, so the wire and the file agree byte for byte. No `id:`:
/// a reaction is not a message, and the client's resume cursor stays on
/// messages.
pub fn reactionFrame(alloc: Alloc, line: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "event: reaction\ndata: {s}\n\n", .{line});
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// What a message frame's `data:` line holds, for assertions.
const Data = struct {
    index: usize,
    from: []const u8,
    at: []const u8,
    html: []const u8,
    markdown: []const u8,
    id: []const u8,
    cid: ?[]const u8 = null,
};

fn parseData(a: Alloc, frame: []const u8) !std.json.Parsed(Data) {
    const pfx = "data: ";
    const start = (std.mem.indexOf(u8, frame, pfx) orelse return error.NoData) + pfx.len;
    const end = (std.mem.indexOf(u8, frame[start..], "\n\n") orelse return error.NoEnd) + start;
    return std.json.parseFromSlice(Data, a, frame[start..end], .{});
}

test "messageFrame: id is the index, fields JSON-escaped, html rendered, no mine, empty cid omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const frame = try messageFrame(a, .{ .index = 7, .from = "A\"B", .at = "2026-10-25T12:00:00Z", .id = "t_8", .markdown = "**hi**" });
    try testing.expect(std.mem.startsWith(u8, frame, "id: 7\ndata: {"));
    try testing.expect(std.mem.endsWith(u8, frame, "}\n\n"));
    // One data line: the JSON escapes every newline it carries.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, frame, "\n"));
    try testing.expect(std.mem.indexOf(u8, frame, "\"mine\"") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"cid\"") == null);

    const p = try parseData(a, frame);
    try testing.expectEqual(@as(usize, 7), p.value.index);
    try testing.expectEqualStrings("A\"B", p.value.from);
    try testing.expectEqualStrings("2026-10-25T12:00:00Z", p.value.at);
    try testing.expectEqualStrings(try markdown.render(a, "**hi**"), p.value.html);
    try testing.expectEqualStrings("**hi**", p.value.markdown);
    try testing.expectEqualStrings("t_8", p.value.id);
}

test "messageFrame: a cid rides last, and a multi-line message is still one data line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = try messageFrame(a, .{ .index = 0, .from = "Steve", .at = "d", .id = "t_1", .markdown = "one\n\ntwo\n```\ncode\n```", .cid = "c-9" });
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, frame, "\n"));
    try testing.expect(std.mem.endsWith(u8, frame, ",\"cid\":\"c-9\"}\n\n"));
    try testing.expectEqualStrings("c-9", (try parseData(a, frame)).value.cid.?);
}

test "reactionFrame carries the sidecar line verbatim as an event: reaction" {
    const line = "{\"msg\":2,\"uid\":\"1\",\"from\":\"Steve\",\"emoji\":\"👍\",\"on\":true,\"at\":\"2026-09-10T12:00:00Z\"}";
    const frame = try reactionFrame(testing.allocator, line);
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("event: reaction\ndata: " ++ line ++ "\n\n", frame);
}
