//! images: /chat/images/stream, the per-user image transcript's live half: a
//! per-uid subscriber on the images bus (live-only; the page is the backlog),
//! fed by the fanout. The page is the Roc's (roc-webbox chat/main.roc
//! `feed!`, chat/Feeds.roc), as the same imagesSSEEvent shape images.js uses
//! for its first paint and for the stream's upserts.

const std = @import("std");
const chat_fanout = @import("chat_fanout.zig");
const sse = @import("webbox").sse;
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// handle serves /chat/images/stream — `rest` is the path after "/images".
pub fn handle(req: *Request, alloc: Alloc, bus: *Bus, uid: []const u8, rest: []const u8) !void {
    if (std.mem.eql(u8, rest, "/stream")) {
        return sse.forward(req, bus, try chat_fanout.imagesBusKey(alloc, uid));
    }
    // The page and every other path under it are the Roc's (roc-webbox
    // chat/main.roc `feed!`); only the stream comes here.
    std.debug.panic("images.handle: {s} is the Roc's", .{rest});
}
