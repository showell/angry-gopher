//! **THE OLD ZIG, KEPT AS THE ROC'S ORACLE** (roc-webbox docs/ROC-CHAT.md
//! C4): a /chat or /channel request served as before the Roc took a topic's
//! reactions, react, pin and unpin: decided by the Zig parse the router
//! replaced (chat_route_twin.zig), and those four served by their Zig
//! handlers as they were at angry-gopher dc3445e (reactions.zig `serveFile`
//! and `handleReact`, chat.zig `pinTopic`). chat_router.zig runs it when a
//! test sets `test_oracle`; chat_actions_twin_test.zig runs the same
//! requests both ways, on two copies of one tree, and holds the answers and
//! the files they leave to each other. Test-only: it goes when the Roc has
//! no more to prove.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const Bus = webbox.bus.Bus;
const roc_chat = @import("roc_chat");
const chat = @import("chat.zig");
const chat_router = @import("chat_router.zig");
const chat_route_twin = @import("chat_route_twin.zig");
const presence = @import("presence.zig");
const reactions = @import("reactions.zig");
const chat_state = @import("chat_state.zig");
const store = @import("chat_store.zig");
const Now = @import("request_time.zig").Now;

const Request = std.http.Server.Request;
const Alloc = std.mem.Allocator;

pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8, channel: bool) !void {
    const now = chat_router.test_now orelse Now.read(io);
    var call: chat_router.Call = .{ .req = req, .io = io, .alloc = alloc, .bus = bus, .now = now };
    // A static script before the gate, asking nobody.
    const first = try chat_route_twin.decide(alloc, sub, channel, true);
    if (first == .serve and first.serve.route.family == .asset) return chat.serve(req, io, alloc, bus, "", first.serve.route, now);
    const member = chat_router.Call.member(&call);
    if (call.failed) |e| return e;
    const decision = try chat_route_twin.decide(alloc, sub, channel, member);
    switch (decision) {
        .redirect => |location| return http.redirect(req, location),
        .serve => |s| {
            if (s.presence) presence.markActiveAndBroadcast(io, alloc, bus, call.uid, now);
            const r = s.route;
            if ((r.family == .dm or r.family == .channel) and r.part == .topic) switch (r.tail) {
                .reactions, .react, .pin, .unpin => {
                    // The 404s are chat.zig's, as ever.
                    const t = (try chat.findTopic(io, alloc, call.uid, r)) orelse return chat.serve(req, io, alloc, bus, call.uid, r, now);
                    return switch (r.tail) {
                        .reactions => serveFile(req, io, alloc, t.dir, t.sid),
                        .react => handleReact(req, io, alloc, bus, t.dir, t.key, t.sid, call.uid, now),
                        .pin => pinTopic(req, io, alloc, call.uid, t.key, t.sid, true),
                        else => pinTopic(req, io, alloc, call.uid, t.key, t.sid, false),
                    };
                },
                else => {},
            };
            return chat.serve(req, io, alloc, bus, call.uid, r, now);
        },
        else => unreachable,
    }
}

/// serveFile answers GET /<…>/<sid>/reactions with the sidecar's bytes.
fn serveFile(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const bytes = try store.readReactions(io, alloc, conv_dir, sid);
    try req.respond(bytes, .{ .extra_headers = &.{http.ndjson_ct} });
}

/// handleReact answers POST /<…>/<sid>/react: validate the three fields, append
/// the event (which fans out live), 204. Bad input is a 400 with a one-line
/// reason; `msg` beyond the transcript's count is one of them.
fn handleReact(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8, now: Now) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const body = (try http.readLimitedBody(req, alloc, reactions.max_body_bytes)) orelse return;
    const r = switch (try reactions.parseReactForm(alloc, body)) {
        .bad => |why| return req.respond(why, .{ .status = .bad_request }),
        .reacted => |r| r,
    };
    switch (try reactions.storeReaction(io, alloc, bus, .{ .dir = conv_dir, .key = conv_key, .sid = sid }, uid, now, r)) {
        .stored => try req.respond("", .{ .status = .no_content }),
        .no_such_message => try req.respond("react: no such message\n", .{ .status = .bad_request }),
    }
}

/// pinTopic handles POST /<…>/<sid>/{pin,unpin}: toggle whether `sid` is in
/// the caller's per-conv Pinned group, then 204.
fn pinTopic(req: *Request, io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8, pinned: bool) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    try chat_state.setTopicPinned(io, alloc, uid, conv_key, sid, pinned);
    return req.respond("", .{ .status = .no_content });
}
