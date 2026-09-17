//! chat_sse: the live wire protocol for the chat surface — Server-Sent Events.
//! Two stream shapes plus the framing they share:
//!
//!   streamTranscript   /<conv>/<sid>/stream — per-topic: a `backlog-size`
//!                      preamble, backlog replay from the cursor, then LIVE
//!                      messages off the bus, with `: ping` keepalives.
//!   forwardUserStream  the per-uid cross-page streams (notifications, sidebar,
//!                      recent, images, code) — subscribe to one bus key and
//!                      forward each published blob verbatim as one SSE frame.
//!
//! emitWire/liveFrame/BusMsg are the per-topic framing (render markdown → html,
//! compute viewer-relative `mine`); parseSince is the replay cursor. The bus
//! fan-out itself lives in bus.zig; openStream (decode backlog + subscribe
//! atomically) in chat_store.zig — this module is purely the HTTP/SSE edge.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const markdown = @import("markdown.zig");
const Bus = @import("bus.zig").Bus;

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
    const since = try parseSince(req, alloc);
    const viewer = try users.getUserName(io, alloc, uid);

    const stream = try store.openStream(io, alloc, bus, conv_dir, conv_key, sid);
    // This handler owns the subscriber until the host takes it.
    var kept = false;
    defer if (!kept) bus.close(stream.sub);

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &http.sse_headers, .transfer_encoding = .none },
    }) catch return;

    const backlog_size = if (stream.backlog.len > since) stream.backlog.len - since else 0;
    {
        const pre = try std.fmt.allocPrint(alloc, "event: backlog-size\ndata: {d}\n\n", .{backlog_size});
        http.pushFrame(&body, pre) catch return;
    }

    var i: usize = since;
    while (i < stream.backlog.len) : (i += 1) {
        const m = stream.backlog[i];
        const frame = try emitWire(alloc, i, m.from, m.date, m.markdown, m.id, std.mem.eql(u8, m.from, viewer), "");
        http.pushFrame(&body, frame) catch return;
    }

    // Live: the host's. The viewer outlives this request's arena.
    bus.keep(.{ .sub = stream.sub, .render = renderLive, .ctx = try bus.gpa().dupe(u8, viewer) });
    kept = true;
}

/// One live frame for this viewer, or nothing if the blob does not render.
fn renderLive(viewer: []const u8, arena: Alloc, raw: []const u8) ?[]const u8 {
    return liveFrame(arena, raw, viewer) catch null;
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

// ── per-uid cross-page stream ─────────────────────────────────────────────────

/// forwardUserStream subscribes to a per-uid cross-page bus key (recent/images)
/// and hands it to the host, which forwards each published blob verbatim as one
/// SSE `data:` frame. Live-only (the server-rendered page is the backlog); the
/// host sends the `: ping` keepalives. The published blob is already the exact
/// event JSON the page's client parses.
pub fn forwardUserStream(req: *Request, alloc: Alloc, bus: *Bus, key: []const u8) !void {
    _ = alloc;
    const sub = try bus.open(key);
    var kept = false;
    defer if (!kept) bus.close(sub);

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &http.sse_headers, .transfer_encoding = .none },
    }) catch return;
    // Send the head now: a live-only stream may have nothing to say for a
    // while, and the browser should know it is connected.
    body.flush() catch return;

    bus.keep(.{ .sub = sub, .render = renderForward });
    kept = true;
}

fn renderForward(_: []const u8, arena: Alloc, blob: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(arena, "data: {s}\n\n", .{blob}) catch null;
}

// ── replay cursor ──────────────────────────────────────────────────────────────

/// parseSince extracts the replay cursor from the request: Last-Event-ID
/// (reconnect) → n+1, else ?since=N (initial load) → n, else 0. The decision is
/// sinceFrom; this is just the Io-free read of the two header/query sources.
fn parseSince(req: *Request, alloc: Alloc) !usize {
    return sinceFrom(try http.header(req, alloc, "last-event-id"), http.queryValue(try http.target(req, alloc), "since"));
}

/// sinceFrom is the pure replay-cursor decision: a parseable Last-Event-ID wins
/// (reconnect resumes AFTER the last delivered id → n+1); else a parseable
/// ?since=N (initial load resumes AT n); else 0. A malformed source falls through
/// to the next, so a junk Last-Event-ID doesn't strand a valid ?since.
fn sinceFrom(last_event_id: ?[]const u8, since_q: ?[]const u8) usize {
    if (last_event_id) |lei| {
        const t = std.mem.trim(u8, lei, " \t");
        if (std.fmt.parseInt(usize, t, 10)) |n| return n + 1 else |_| {}
    }
    if (since_q) |q| {
        if (std.fmt.parseInt(usize, q, 10)) |n| return n else |_| {}
    }
    return 0;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "sinceFrom: Last-Event-ID resumes after n; ?since resumes at n; junk falls through" {
    // Last-Event-ID (reconnect) → n+1
    try testing.expectEqual(@as(usize, 6), sinceFrom("5", null));
    try testing.expectEqual(@as(usize, 6), sinceFrom("  5 ", null)); // trimmed
    // ?since (initial load) → n
    try testing.expectEqual(@as(usize, 5), sinceFrom(null, "5"));
    // neither present → 0
    try testing.expectEqual(@as(usize, 0), sinceFrom(null, null));
    // Last-Event-ID wins over ?since when both are present and valid
    try testing.expectEqual(@as(usize, 6), sinceFrom("5", "99"));
    // a junk Last-Event-ID must NOT strand a valid ?since — it falls through
    try testing.expectEqual(@as(usize, 5), sinceFrom("garbage", "5"));
    // both unparseable → 0
    try testing.expectEqual(@as(usize, 0), sinceFrom("x", "y"));
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

test "renderForward wraps a blob as one data frame; renderLive passes the viewer through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("data: {\"x\":1}\n\n", renderForward("", a, "{\"x\":1}").?);
    const blob = "{\"index\":0,\"from\":\"Ann\",\"at\":\"2pm\",\"id\":\"general_1\",\"cid\":\"\",\"markdown\":\"hi\"}";
    // A blob that does not parse renders nothing, rather than a broken frame.
    try testing.expect(renderLive("Ann", a, "{\"index\":0}") == null);
    const mine = renderLive("Ann", a, blob).?;
    const theirs = renderLive("Bob", a, blob).?;
    try testing.expect(std.mem.indexOf(u8, mine, "\"mine\":true") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "\"mine\":false") != null);
}
