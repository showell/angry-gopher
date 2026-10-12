//! chat_sse: the live wire protocol for the chat surface — Server-Sent Events.
//! Two stream shapes plus the framing they share:
//!
//!   streamTranscript   /<conv>/<sid>/stream — per-topic: a `backlog-size`
//!                      preamble, backlog replay from the cursor, then LIVE
//!                      messages off the bus, with `: ping` keepalives.
//!   the per-uid cross-page streams (notifications, sidebar, recent, images,
//!                      code) are webbox's sse.forward over one bus key each:
//!                      each published blob verbatim as one SSE frame.
//!
//! emitWire/liveFrame/BusMsg are the per-topic framing (render markdown → html,
//! compute viewer-relative `mine`); the replay cursor is sse.readResume. The bus
//! fan-out itself lives in bus.zig; openStream (decode backlog + subscribe
//! atomically) in chat_store.zig — this module is purely the HTTP/SSE edge.
//! The bus was prototyped on a standalone concurrency spike (since removed)
//! before chat was ported onto it.
//!
//! Every chat stream's head, preamble and backlog go through webbox's sse.zig
//! (`respond`, `push`); the live frames are the host's (bus.zig's `Kept`).

const std = @import("std");
const Io = std.Io;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");
const Bus = @import("bus.zig").Bus;
const sse = @import("sse.zig");
const http = @import("http.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

// ── per-topic stream (backlog replay + live + keepalive) ──────────────────────

/// streamTranscript serves /<…>/<sid>/stream: the `backlog-size` preamble and
/// the backlog replay from the cursor, then hands the LIVE part to the host (a
/// message posted to this conv/sid via /send fans out to it), which also sends
/// the `: ping` keepalives. openStream decodes the backlog and subscribes
/// atomically, so each message lands in EITHER the backlog OR the live stream —
/// never both, never neither.
///
/// **THE BODY IS DELIMITED BY THE CONNECTION CLOSING**, not chunked: the host
/// writes each live frame as it is, long after this handler has returned, and
/// there is no chunk framing for it to carry on.
pub fn streamTranscript(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8) !void {
    // A stream is a GET's (metal-vmm QUEUE 176.3).
    if (req.head.method != .GET) return http.methodNotAllowed(req);
    const since = try sse.readResume(req, alloc);
    const viewer = try users.getUserName(io, alloc, uid);

    const stream = try store.openStream(io, alloc, bus, conv_dir, conv_key, sid);
    // This handler owns the subscriber until the host takes it.
    var held = bus.hold(stream.sub);
    defer held.release();

    var hbuf: [4096]u8 = undefined;
    var body = sse.respond(req, &hbuf) catch return;

    const rest = backlogFrom(stream.backlog, sid, since);
    {
        const pre = try std.fmt.allocPrint(alloc, "event: backlog-size\ndata: {d}\n\n", .{rest.len});
        sse.push(&body, pre) catch return;
    }

    const first = stream.backlog.len - rest.len;
    for (rest, first..) |m, i| {
        // Its index from its id, as the live stream's: a refused block before
        // it keeps its number (chat_store.countBlocks).
        const index = store.indexOf(m.id, sid) orelse i;
        const frame = try emitWire(alloc, index, m.from, m.date, m.markdown, m.id, std.mem.eql(u8, m.from, viewer), "");
        sse.push(&body, frame) catch return;
    }

    // Live: the host's. The viewer outlives this request's arena.
    held.keep(renderLive, try bus.gpa().dupe(u8, viewer));
}

/// One live frame for this viewer, or nothing if the blob is no message;
/// memory that runs out ends the stream, to be resumed (metal-vmm QUEUE 172).
fn renderLive(viewer: []const u8, arena: Alloc, raw: []const u8) Alloc.Error!?[]const u8 {
    return liveFrame(arena, raw, viewer) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// The fan-out blob shape appendMessage publishes (every wire field except the
/// per-viewer `mine` and the per-stream-rendered `html`).
const BusMsg = struct {
    index: usize,
    from: []const u8,
    at: []const u8,
    id: []const u8,
    cid: []const u8,
    markdown: []const u8,
};

/// A reaction event rides the same topic key as messages, wrapped by
/// chat_store.appendReaction as `{"reaction":<line>}`; the unwrapped line is the
/// sidecar's own line, so the wire and the file agree byte-for-byte.
const reaction_prefix = "{\"reaction\":";

/// liveFrame turns one bus blob into this viewer's SSE event: a reaction blob
/// becomes `event: reaction` carrying the sidecar line verbatim; a message blob
/// is parsed, its markdown rendered, `mine` computed against the viewer's name.
fn liveFrame(alloc: Alloc, raw: []const u8, viewer: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw, reaction_prefix) and raw.len > reaction_prefix.len + 1) {
        return std.fmt.allocPrint(alloc, "event: reaction\ndata: {s}\n\n", .{raw[reaction_prefix.len .. raw.len - 1]});
    }
    const parsed = try std.json.parseFromSlice(BusMsg, alloc, raw, .{});
    defer parsed.deinit();
    const m = parsed.value;
    return emitWire(alloc, m.index, m.from, m.at, m.markdown, m.id, std.mem.eql(u8, m.from, viewer), m.cid);
}

/// emitWire builds one SSE message event:
/// `id: <index>` then a `data:` line of JSON. `html` is rendered from `markdown`
/// via the markdown port; `mine` is viewer-relative; `cid` is included only when
/// non-empty.
fn emitWire(alloc: Alloc, index: usize, from: []const u8, at: []const u8, md: []const u8, id: []const u8, mine: bool, cid: []const u8) ![]const u8 {
    const rendered = try markdown.render(alloc, md);
    if (cid.len > 0) {
        return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f},\"mine\":{},\"cid\":{f}}}\n\n", .{
            index,                       index,
            std.json.fmt(from, .{}),     std.json.fmt(at, .{}),
            std.json.fmt(rendered, .{}), std.json.fmt(md, .{}),
            std.json.fmt(id, .{}),       mine,
            std.json.fmt(cid, .{}),
        });
    }
    return std.fmt.allocPrint(alloc, "id: {d}\ndata: {{\"index\":{d},\"from\":{f},\"at\":{f},\"html\":{f},\"markdown\":{f},\"id\":{f},\"mine\":{}}}\n\n", .{
        index,                       index,
        std.json.fmt(from, .{}),     std.json.fmt(at, .{}),
        std.json.fmt(rendered, .{}), std.json.fmt(md, .{}),
        std.json.fmt(id, .{}),       mine,
    });
}

// ── replay cursor ──────────────────────────────────────────────────────────────

/// The backlog from index `since` on (webbox's sse.readResume says where a
/// stream resumes). **AN INDEX, NOT A POSITION**: a frame's
/// `id:` is its message's index, so a refused block before it leaves the
/// backlog's positions behind the indexes after it.
fn backlogFrom(backlog: []const store.ChatMessage, sid: []const u8, since: usize) []const store.ChatMessage {
    for (backlog, 0..) |m, i| {
        if ((store.indexOf(m.id, sid) orelse i) >= since) return backlog[i..];
    }
    return backlog[backlog.len..];
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a reconnect past a refused block misses nothing: since is an index, not a position in the backlog" {
    // t_2 was refused, so the backlog holds t_1, t_3, t_4. A client that saw
    // t_3 (its id: 2) reconnects with since = 3 and must get t_4.
    const m = struct {
        fn of(id: []const u8) store.ChatMessage {
            return .{ .id = id, .from = "a", .date = "d", .markdown = "x" };
        }
    };
    const backlog = [_]store.ChatMessage{ m.of("t_1"), m.of("t_3"), m.of("t_4") };
    const rest = backlogFrom(&backlog, "t", 3);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqualStrings("t_4", rest[0].id);
    try testing.expectEqual(@as(usize, 3), backlogFrom(&backlog, "t", 0).len);
    try testing.expectEqual(@as(usize, 2), backlogFrom(&backlog, "t", 1).len); // t_3 is index 2
    try testing.expectEqual(@as(usize, 0), backlogFrom(&backlog, "t", 4).len);
}

/// wireField pulls one field out of an emitted SSE message frame for assertions:
/// it strips the `id: N\n` line, then JSON-parses the `data:` payload into `T`.
/// (emitWire's html is markdown.render output — markdown has its own gold tests,
/// so here we check chat_sse's framing/escaping/mine/cid contract, not the HTML.)
fn parseWire(comptime T: type, a: Alloc, frame: []const u8) !std.json.Parsed(T) {
    const pfx = "data: ";
    const start = (std.mem.indexOf(u8, frame, pfx) orelse return error.NoData) + pfx.len;
    const end = (std.mem.indexOf(u8, frame[start..], "\n\n") orelse return error.NoEnd) + start;
    return std.json.parseFromSlice(T, a, frame[start..end], .{});
}

test "liveFrame unwraps a reaction blob into an event: reaction frame carrying the line verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "{\"msg\":2,\"uid\":\"1\",\"from\":\"Steve\",\"emoji\":\"👍\",\"on\":true,\"at\":\"2026-09-10T12:00:00Z\"}";
    const blob = try std.fmt.allocPrint(a, "{{\"reaction\":{s}}}", .{line});
    const frame = try liveFrame(a, blob, "Steve");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "event: reaction\ndata: {s}\n\n", .{line}), frame);
}

const WireView = struct {
    index: usize,
    from: []const u8,
    at: []const u8,
    html: []const u8,
    markdown: []const u8,
    id: []const u8,
    mine: bool,
    cid: ?[]const u8 = null, // omitted from the wire when empty
};

test "emitWire frames id/index/mine, round-trips JSON-escaped fields, and omits empty cid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // a name with a double-quote exercises JSON escaping on the wire
    const frame = try emitWire(a, 7, "A\"B", "2pm", "hi", "MSG_1", true, "");
    try testing.expect(std.mem.startsWith(u8, frame, "id: 7\n")); // SSE id = index
    try testing.expect(std.mem.endsWith(u8, frame, "\n\n"));

    const p = try parseWire(WireView, a, frame);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 7), p.value.index);
    try testing.expectEqualStrings("A\"B", p.value.from); // escaping round-trips
    try testing.expectEqualStrings("hi", p.value.markdown); // raw markdown preserved
    try testing.expectEqualStrings("MSG_1", p.value.id);
    try testing.expect(p.value.mine);
    try testing.expect(p.value.cid == null); // empty cid omitted

    // a non-empty cid is included
    const frame2 = try emitWire(a, 8, "Steve", "3pm", "yo", "MSG_2", false, "c-9");
    const p2 = try parseWire(WireView, a, frame2);
    defer p2.deinit();
    try testing.expect(!p2.value.mine);
    try testing.expectEqualStrings("c-9", p2.value.cid.?);
}

test "liveFrame computes mine against the viewer from a bus blob" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = "{\"index\":3,\"from\":\"Steve\",\"at\":\"2pm\",\"id\":\"MSG_2\",\"cid\":\"c-1\",\"markdown\":\"yo\"}";

    // same name as the author → mine:true, and cid passes through
    const mine = try parseWire(WireView, a, try liveFrame(a, raw, "Steve"));
    defer mine.deinit();
    try testing.expect(mine.value.mine);
    try testing.expectEqualStrings("c-1", mine.value.cid.?);
    try testing.expectEqual(@as(usize, 3), mine.value.index);

    // a different viewer → mine:false (the one viewer-relative field)
    const theirs = try parseWire(WireView, a, try liveFrame(a, raw, "apoorva"));
    defer theirs.deinit();
    try testing.expect(!theirs.value.mine);
}

test "renderLive passes the viewer through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = "{\"index\":0,\"from\":\"Ann\",\"at\":\"2pm\",\"id\":\"general_1\",\"cid\":\"\",\"markdown\":\"hi\"}";
    // A blob that does not parse renders nothing, rather than a broken frame.
    try testing.expect(try renderLive("Ann", a, "{\"index\":0}") == null);
    const mine = (try renderLive("Ann", a, blob)).?;
    const theirs = (try renderLive("Bob", a, blob)).?;
    try testing.expect(std.mem.indexOf(u8, mine, "\"mine\":true") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "\"mine\":false") != null);
}
