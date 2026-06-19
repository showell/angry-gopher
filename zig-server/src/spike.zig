//! spike: a throwaway-tenant proof of the chat concurrency runtime, with ZERO
//! chat semantics. It exists to settle one architectural question before chat is
//! ported — can this single-binary zig server hold many live connections open at
//! once and fan a message out across them? — using a toy clock + a toy broadcast
//! instead of real chat streams. The two unknowns the games couldn't rehearse,
//! isolated: connection concurrency (server.zig runs each connection on the std
//! .Io thread pool) and pub/sub fan-out (bus.zig, the Go subBus analog).
//!
//! Three endpoints under /spike:
//!   GET  /spike            an index page that opens both SSE streams + a
//!                          broadcast box, so a human can open N tabs and watch.
//!   GET  /spike/clock      SSE: a per-connection 1Hz tick. Many open at once
//!                          prove a long-lived stream no longer starves the
//!                          accept loop (the /game keep-alive deadlock, deliberate
//!                          this time, on a trivial endpoint).
//!   GET  /spike/events     SSE: subscribes to the bus and emits every broadcast.
//!   POST /spike/broadcast  publishes its body to every open /spike/events stream
//!                          (also accepts GET ?msg=… for quick curl tests).
//!
//! When this proves out, bus.zig graduates into chat verbatim and these toy
//! handlers are deleted — the runtime + the bus are the keepers, not the toys.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;

/// The single fan-out key the spike uses (chat will key by conv/user id).
const broadcast_key = "all";

const sse_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    // Defeat any reverse-proxy buffering (Caddy/nginx) so frames arrive live.
    .{ .name = "x-accel-buffering", .value = "no" },
};

pub fn handle(req: *std.http.Server.Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try req.respond(index_page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/clock")) {
        try clockStream(req, io);
    } else if (std.mem.eql(u8, sub, "/events")) {
        try eventStream(req, bus);
    } else if (std.mem.eql(u8, sub, "/broadcast")) {
        try broadcast(req, alloc, bus);
    } else {
        try http.notFound(req);
    }
}

/// pushFrame sends one SSE frame live. Two flushes are required and the order
/// matters: body.writer.flush() drains the chunked BodyWriter's own buffer into
/// the protocol output (emitting the HTTP chunk), then body.flush() pushes that
/// chunk out the socket. body.flush() alone is a no-op while bytes still sit in
/// the writer buffer — the subtle bit that makes SSE actually stream.
fn pushFrame(body: *std.http.BodyWriter, bytes: []const u8) !void {
    try body.writer.writeAll(bytes);
    try body.writer.flush();
    try body.flush();
}

/// clockStream emits ": ok" then a `data:` tick every second, forever, until the
/// client disconnects (a failed write/flush ends the loop). Proves connection
/// concurrency: each one holds a pool thread blocked in io.sleep without
/// starving the accept loop or the other streams.
fn clockStream(req: *std.http.Server.Request, io: Io) !void {
    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &sse_headers },
    }) catch return;

    pushFrame(&body, ": ok\n\n") catch return;

    var n: u64 = 0;
    while (true) {
        const secs = @divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s);
        var fbuf: [64]u8 = undefined;
        const frame = std.fmt.bufPrint(&fbuf, "data: tick {d} @ {d}\n\n", .{ n, secs }) catch return;
        pushFrame(&body, frame) catch return;
        n += 1;
        io.sleep(.fromSeconds(1), .awake) catch return;
    }
}

/// eventStream subscribes to the bus and writes every published message as an
/// SSE `data:` frame, with a `: ping` keepalive when idle. Proves fan-out: many
/// of these open at once, one POST /spike/broadcast reaches all of them.
fn eventStream(req: *std.http.Server.Request, bus: *Bus) !void {
    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &sse_headers },
    }) catch return;

    const subr = bus.open(broadcast_key) catch return;
    defer bus.close(subr);

    pushFrame(&body, ": ok\n\n") catch return;

    while (true) {
        switch (subr.next()) {
            .msg => |m| {
                defer subr.alloc.free(m);
                var fbuf: [80 * 1024]u8 = undefined;
                const frame = std.fmt.bufPrint(&fbuf, "data: {s}\n\n", .{m}) catch continue;
                pushFrame(&body, frame) catch return;
            },
            .idle => pushFrame(&body, ": ping\n\n") catch return,
        }
    }
}

/// broadcast publishes a message to every open /spike/events stream. Body for
/// POST, or ?msg=… for a GET (so `curl localhost:9001/spike/broadcast?msg=hi`
/// works). Replies with the number of streams that received it.
fn broadcast(req: *std.http.Server.Request, alloc: Alloc, bus: *Bus) !void {
    var msg: []const u8 = "";
    if (queryValue(req.head.target, "msg")) |q| {
        msg = q;
    } else {
        const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
        msg = std.mem.trim(u8, body, " \t\r\n");
    }
    if (msg.len == 0) {
        try req.respond("empty message\n", .{ .status = .bad_request });
        return;
    }
    bus.publish(broadcast_key, msg);
    const n = bus.subscriberCount(broadcast_key);
    const reply = try std.fmt.allocPrint(alloc, "delivered to {d} stream(s)\n", .{n});
    try req.respond(reply, .{ .extra_headers = &.{http.plain_ct} });
}

/// queryValue pulls a single (un-decoded) query parameter out of a raw request
/// target like "/spike/broadcast?msg=hello". Spike-grade: no %-decoding, first
/// match wins, returns null if absent. (chat will reuse the real parser.)
fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

const index_page =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>concurrency spike</title>
    \\<style>
    \\  body { font: 14px/1.5 system-ui, sans-serif; margin: 2rem; max-width: 60rem; }
    \\  h1 { font-size: 1.2rem; }
    \\  .panes { display: flex; gap: 1rem; }
    \\  .pane { flex: 1; border: 1px solid #ccc; border-radius: 6px; padding: .5rem .75rem; }
    \\  .pane h2 { font-size: .95rem; margin: .25rem 0 .5rem; }
    \\  pre { height: 14rem; overflow-y: auto; background: #f6f6f6; padding: .5rem;
    \\        border-radius: 4px; margin: 0; white-space: pre-wrap; }
    \\  form { margin: 1rem 0; }
    \\  input[type=text] { width: 20rem; padding: .3rem; }
    \\  button { padding: .3rem .8rem; }
    \\  .hint { color: #666; }
    \\</style></head><body>
    \\<h1>zig server — concurrency spike</h1>
    \\<p class="hint">Open this page in several tabs. The <b>clock</b> proves many
    \\long-lived streams coexist; <b>broadcast</b> proves fan-out reaches every tab.</p>
    \\<form id="bc">
    \\  <input type="text" id="msg" placeholder="message to broadcast" autofocus>
    \\  <button type="submit">Broadcast to all tabs</button>
    \\  <span id="ack" class="hint"></span>
    \\</form>
    \\<div class="panes">
    \\  <div class="pane"><h2>/spike/clock (per-connection 1Hz)</h2><pre id="clock"></pre></div>
    \\  <div class="pane"><h2>/spike/events (fan-out)</h2><pre id="events"></pre></div>
    \\</div>
    \\<script>
    \\  const log = (id, s) => { const el = document.getElementById(id);
    \\    el.textContent += s + "\n"; el.scrollTop = el.scrollHeight; };
    \\  new EventSource("/spike/clock").onmessage  = e => log("clock", e.data);
    \\  new EventSource("/spike/events").onmessage = e => log("events", e.data);
    \\  document.getElementById("bc").addEventListener("submit", async ev => {
    \\    ev.preventDefault();
    \\    const msg = document.getElementById("msg").value;
    \\    if (!msg) return;
    \\    const r = await fetch("/spike/broadcast", { method: "POST", body: msg });
    \\    document.getElementById("ack").textContent = (await r.text()).trim();
    \\    document.getElementById("msg").value = "";
    \\  });
    \\</script>
    \\</body></html>
;
