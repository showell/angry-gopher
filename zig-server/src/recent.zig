//! recent: /chat/recent — a flat reverse-chronological feed of activity across
//! the signed-in user's chat topics (DMs + channels) and personal docs. The
//! page is the Roc's, its rows gathered there too (roc-webbox chat/main.roc
//! `load_recent!`, metal-vmm QUEUE 277), shipped newest-first as inline JSON
//! (the same recentEvent shape the live stream pushes, so recent.js uses one
//! row builder for both paint and upsert). This is its stream.
//!
//! Live stream: /chat/recent/stream is a per-uid subscriber on the recent bus,
//! live-only (the server-rendered page already IS the backlog, so no replay).
//! chat_store.appendMessage fans one event onto the recent bus per write
//! (alongside notify/images/code) and docs save/create do the same, so a new
//! message or doc shows up live. recent.js re-humanizes the "When" column on a
//! 20s timer and upserts rows from onmessage events.

const std = @import("std");
const chat_fanout = @import("chat_fanout.zig");
const sse = @import("webbox").sse;
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// handle dispatches /chat/recent* — `rest` is the path after "/recent"; only
/// the stream comes here, the page and the rest being the Roc's.
pub fn handle(req: *Request, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    // Live: a per-uid subscriber on the recent bus. The server-rendered page IS
    // the backlog, so the stream is live-only (no replay). Fed by the
    // appendMessage cross-page fanout + docs save/create.
    if (std.mem.eql(u8, rest, "/stream")) {
        return sse.forward(req, bus, try chat_fanout.recentBusKey(alloc, uid));
    }
    std.debug.panic("recent.handle: {s} is the Roc's", .{rest});
}
