//! chat_sse: the live wire protocol for the chat surface — Server-Sent Events.
//! Two stream shapes, one way of serving them:
//!
//!   streamTranscript   /<conv>/<sid>/stream — per-topic: a `backlog-size`
//!                      preamble, backlog replay from the cursor, then LIVE
//!                      messages and reactions off the bus, with `: ping`
//!                      keepalives.
//!   the per-uid cross-page streams (notifications, sidebar, recent, images,
//!                      code) are webbox's sse.forward over one bus key each:
//!                      each published blob as one `data:` frame.
//!
//! **WHAT IS PUBLISHED IS WHAT GOES OUT** (chat_frame.zig): a topic's bus blobs
//! are finished SSE frames, built once inside the turn that stored them and the
//! same for every viewer, so the host's render for a kept topic stream copies
//! each through (`verbatim`) — no parse, no markdown, nothing about the viewer,
//! wherever the host runs it (Linux: the connection's own task, outside the
//! turn; one loop: its pump). The replay cursor is sse.readResume; the bus
//! fan-out lives in webbox's bus.zig; openStream (decode backlog + subscribe
//! atomically) in chat_store.zig — this module is purely the HTTP/SSE edge.
//!
//! Every chat stream's head, preamble and backlog go through webbox's sse.zig
//! (`respond`, `push`); the live frames are the host's (bus.zig's `Kept`).

const std = @import("std");
const chat_count = @import("chat_count.zig");
const Io = @import("host_io").Io;
const store = @import("chat_store.zig");
const chat_frame = @import("chat_frame.zig");
const Bus = @import("webbox").bus.Bus;
const sse = @import("webbox").sse;
const http = @import("webbox").http;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

// ── per-topic stream (backlog replay + live + keepalive) ──────────────────────

/// **A TOPIC'S STREAM, AS THE ROC NAMED IT** (metal-vmm QUEUE 286): the
/// transcript to replay (a path the host joined under the chat root), the
/// bus key to hear, and the topic its messages are numbered in.
pub const Replay = struct {
    path: []const u8,
    key: []const u8,
    sid: []const u8,
};

/// streamTranscript serves /<…>/<sid>/stream: the `backlog-size` preamble and
/// the backlog replay from the cursor, then hands the LIVE part to the host (a
/// message posted to this conv/sid via /send fans out to it), which also sends
/// the `: ping` keepalives. openStream decodes the backlog and subscribes
/// atomically, so each message lands in EITHER the backlog OR the live stream —
/// never both, never neither. Every viewer of a topic is sent the same bytes.
///
/// **THE BODY IS DELIMITED BY THE CONNECTION CLOSING**, not chunked: the host
/// writes each live frame as it is, long after this handler has returned, and
/// there is no chunk framing for it to carry on.
pub fn streamTranscript(
    req: *Request,
    io: Io,
    alloc: Alloc,
    bus: *Bus,
    topic: Replay,
) !void {
    // A stream is a GET's (metal-vmm QUEUE 176.3); the Roc said so first.
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const since = try sse.readResume(req, alloc);

    const stream = try store.openStream(
        io,
        alloc,
        bus,
        topic.path,
        topic.key,
    );
    // This handler owns the subscriber until the host takes it.
    var held = bus.hold(stream.sub);
    defer held.release();

    var hbuf: [4096]u8 = undefined;
    var body = sse.respond(req, &hbuf) catch return;

    const rest = backlogFrom(
        stream.backlog,
        topic.sid,
        since,
    );
    {
        const pre = try std.fmt.allocPrint(
            alloc,
            "event: backlog-size\ndata: {d}\n\n",
            .{rest.len},
        );
        sse.push(&body, pre) catch return;
    }

    const first = stream.backlog.len - rest.len;
    for (rest, first..) |m, i| {
        // Its index from its id, as the live stream's: a refused block before
        // it keeps its number (chat_store.countBlocks).
        const index = chat_count.indexOf(m.id, topic.sid) orelse i;
        const frame = try chat_frame.messageFrame(alloc, .{
            .index = index,
            .from = m.from,
            .from_uid = m.uid,
            .at = m.at,
            .id = m.id,
            .markdown = m.markdown,
        });
        sse.push(&body, frame) catch return;
    }

    // Live: the host's, each published frame as it is.
    held.keep(verbatim, "");
}

/// A topic stream's render: the published blob is the frame (chat_frame.zig),
/// so it goes out as it is. It cannot fail, and makes nothing.
fn verbatim(
    _: []const u8,
    _: Alloc,
    blob: []const u8,
) Alloc.Error!?[]const u8 {
    return blob;
}

// ── replay cursor ──────────────────────────────────────────────────────────────

/// The backlog from index `since` on (webbox's sse.readResume says where a
/// stream resumes). **AN INDEX, NOT A POSITION**: a frame's
/// `id:` is its message's index, so a refused block before it leaves the
/// backlog's positions behind the indexes after it.
fn backlogFrom(
    backlog: []const store.ChatMessage,
    sid: []const u8,
    since: usize,
) []const store.ChatMessage {
    for (backlog, 0..) |m, i| {
        if ((chat_count.indexOf(m.id, sid) orelse i) >= since) return backlog[i..];
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
            return .{
                .id = id,
                .from = "a",
                .at = "d",
                .markdown = "x",
            };
        }
    };
    const backlog = [_]store.ChatMessage{
        m.of("t_1"),
        m.of("t_3"),
        m.of("t_4"),
    };
    const rest = backlogFrom(
        &backlog,
        "t",
        3,
    );
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqualStrings("t_4", rest[0].id);
    try testing.expectEqual(@as(usize, 3), backlogFrom(
        &backlog,
        "t",
        0,
    ).len);
    try testing.expectEqual(@as(usize, 2), backlogFrom(
        &backlog,
        "t",
        1,
    ).len); // t_3 is index 2
    try testing.expectEqual(@as(usize, 0), backlogFrom(
        &backlog,
        "t",
        4,
    ).len);
}

test "a topic stream's render sends the published frame as it is" {
    const frame = "id: 3\ndata: {\"index\":3}\n\n";
    try testing.expectEqualStrings(frame, (try verbatim(
        "",
        testing.allocator,
        frame,
    )).?);
}

test {
    // The frames' own tests, run with this file's (chat_frame.zig has no binary of its own).
    _ = chat_frame;
}
