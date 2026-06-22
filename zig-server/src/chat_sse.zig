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

/// streamTranscript serves /<…>/<sid>/stream: the `backlog-size` preamble, the
/// backlog replay from the cursor, then LIVE messages off the bus (a message
/// posted to this conv/sid via /send fans out here), with `: ping` keepalives
/// when idle. openStream decodes the backlog and subscribes atomically, so each
/// message lands in EITHER the backlog OR the live stream — never both, never
/// neither.
pub fn streamTranscript(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8) !void {
    const since = parseSince(req);
    const viewer = try users.getUserName(io, alloc, uid);

    const stream = try store.openStream(io, alloc, bus, conv_dir, conv_key, sid);
    defer bus.close(stream.sub);

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &http.sse_headers },
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

    // Live: drain the subscriber. `.msg` is one fan-out blob (caller frees);
    // `.idle` is the keepalive window — send a ping so a vanished client is
    // noticed (the failed write ends the loop and the defer closes the sub).
    while (true) {
        switch (stream.sub.next()) {
            .msg => |raw| {
                defer stream.sub.alloc.free(raw);
                const frame = liveFrame(alloc, raw, viewer) catch continue;
                http.pushFrame(&body, frame) catch return;
            },
            .idle => http.pushFrame(&body, ": ping\n\n") catch return,
        }
    }
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

/// liveFrame turns one bus blob into this viewer's SSE event: parse it, render
/// html from the markdown, compute `mine` against the viewer's name, emit.
fn liveFrame(alloc: Alloc, raw: []const u8, viewer: []const u8) ![]const u8 {
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
/// and forwards each published blob verbatim as one SSE `data:` frame. Live-only
/// (the server-rendered page is the backlog); `: ping` keepalive when idle. The
/// published blob is already the exact event JSON the page's client parses.
pub fn forwardUserStream(req: *Request, alloc: Alloc, bus: *Bus, key: []const u8) !void {
    const sub = try bus.open(key);
    defer bus.close(sub);

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &http.sse_headers },
    }) catch return;

    while (true) {
        switch (sub.next()) {
            .msg => |blob| {
                defer sub.alloc.free(blob);
                const frame = std.fmt.allocPrint(alloc, "data: {s}\n\n", .{blob}) catch continue;
                http.pushFrame(&body, frame) catch return;
            },
            .idle => http.pushFrame(&body, ": ping\n\n") catch return,
        }
    }
}

// ── replay cursor ──────────────────────────────────────────────────────────────

/// parseSince extracts the replay cursor: Last-Event-ID (reconnect) → n+1, else
/// ?since=N (initial load) → n, else 0.
fn parseSince(req: *Request) usize {
    if (http.header(req, "last-event-id")) |lei| {
        const t = std.mem.trim(u8, lei, " \t");
        if (std.fmt.parseInt(usize, t, 10)) |n| return n + 1 else |_| {}
    }
    if (http.queryValue(req.head.target, "since")) |q| {
        if (std.fmt.parseInt(usize, q, 10)) |n| return n else |_| {}
    }
    return 0;
}
