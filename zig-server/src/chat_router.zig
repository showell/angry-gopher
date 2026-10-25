//! **EVERY /chat AND /channel REQUEST, THROUGH THE ROC ROUTER** (roc-webbox
//! docs/ROC-CHAT.md §3, milestone 1): the Roc chat (`roc_chat`, its
//! chat/main.roc) runs the prelude and parses the path; chat.zig serves the
//! route it answers, once the Roc call has ended.
//!
//! The prelude is the Roc's: a static script is served to anyone; anyone
//! else must be a member or the agent, or is sent to sign in; and anything
//! but a stream counts as presence. Who is asking stays here: the Roc asks
//! (`Host.member!`), after the static scripts, so a script's request does no
//! identity reads, as before.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const Bus = webbox.bus.Bus;
const roc_chat = @import("roc_chat");
const chat = @import("chat.zig");
const users = @import("users.zig");
const presence = @import("presence.zig");
const Now = @import("request_time.zig").Now;

const Request = std.http.Server.Request;
const Alloc = std.mem.Allocator;

/// handle answers `sub`, the path under /chat, or under /channel when
/// `channel`.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8, channel: bool) !void {
    // The request's time, read once: everything it stamps carries it
    // (request_time.zig).
    const now = Now.read(io);
    var who: Who = .{ .req = req, .io = io, .alloc = alloc };
    // **THE ROC'S MEMORY IS THE REQUEST'S**: its call's arena is made from
    // this request's allocator, so nothing it took outlives the request.
    roc_chat.use(alloc);
    const decision = try roc_chat.decide(alloc, sub, channel, .{ .ctx = &who, .ask = Who.ask });
    // A failure the Roc could not be told (the store, reading who it is)
    // fails the request, as it did before the router.
    if (who.failed) |e| return e;
    switch (decision) {
        .redirect => |location| return http.redirect(req, location),
        .serve => |s| {
            if (s.route.family != .asset and !who.asked) std.debug.panic("the Roc router served {f} without asking who is asking", .{s.route});
            if (s.presence) presence.markActiveAndBroadcast(io, alloc, bus, who.uid, now);
            return chat.serve(req, io, alloc, bus, who.uid, s.route, now);
        },
    }
}

/// Who is asking, read when the Roc first asks.
const Who = struct {
    req: *Request,
    io: Io,
    alloc: Alloc,
    uid: []const u8 = "",
    asked: bool = false,
    failed: ?anyerror = null,

    fn ask(ctx: *anyopaque) bool {
        const w: *Who = @ptrCast(@alignCast(ctx));
        w.asked = true;
        // absent-ok: not read as absence: `fail` keeps the error, and handle returns it once the Roc call ends (a C call cannot carry it).
        w.uid = users.currentUserID(w.io, w.alloc, w.req) catch |e| return w.fail(e);
        // NEED_PASSWORD: the whole chat subsystem (DMs, docs, recent, images,
        // code, the conversations API) is members + agents only. A guest
        // (name-only, no password) or a stranger is sent to set a password and
        // returned here: guests may play the game, but chat requires
        // membership.
        // absent-ok: the same: the error is kept and returned, never read as "not a member".
        return users.principalAuthorized(w.io, w.alloc, w.uid) catch |e| w.fail(e);
    }

    fn fail(w: *Who, e: anyerror) bool {
        w.failed = e;
        return false;
    }
};
