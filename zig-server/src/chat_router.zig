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
//!
//! **A TOPIC'S REACTIONS, REACT, PIN AND UNPIN ARE THE ROC'S** (C4): it
//! serves them itself, asking `Call` (below) for presence, the topic, the
//! body and the store's writes, which stay Zig's until C8, and answers what
//! to send. `handle` sends it once the call has ended.

const std = @import("std");
const builtin = @import("builtin");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const Bus = webbox.bus.Bus;
const roc_chat = @import("roc_chat");
const chat = @import("chat.zig");
const users = @import("users.zig");
const presence = @import("presence.zig");
const reactions = @import("reactions.zig");
const recent = @import("recent.zig");
const chat_state = @import("chat_state.zig");
const store = @import("chat_store.zig");
const chat_page = @import("chat_page.zig");
const chat_paths = @import("chat_paths.zig");
const chrome = @import("chat_chrome.zig");
const chat_upload = @import("chat_upload.zig");
const limits = @import("limits.zig");
const markdown = @import("markdown.zig");
const edge = webbox.edge;
const Now = @import("request_time.zig").Now;

const Request = std.http.Server.Request;
const Alloc = std.mem.Allocator;

/// **TESTS ONLY: THE OLD ZIG SERVES** (chat_actions_twin.zig's oracle): when
/// set, a request is decided by the Zig parse the router replaced and its
/// topic's reactions, react, pin and unpin by the Zig handlers C4 replaced,
/// so a test can run the same requests both ways. Never read outside a
/// test: `builtin.is_test` takes the branch out of every other build.
pub var test_oracle: bool = false;

/// **TESTS ONLY: THE REQUEST'S TIME**, when set, for both ways of serving
/// (a reaction is stamped with it). Read only under `builtin.is_test`.
pub var test_now: ?Now = null;

fn requestTime(io: Io) Now {
    if (builtin.is_test) if (test_now) |t| return t;
    return Now.read(io);
}

/// handle answers `sub`, the path under /chat, or under /channel when
/// `channel`.
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8, channel: bool) !void {
    if (builtin.is_test and test_oracle) return @import("chat_actions_twin.zig").handle(req, io, alloc, bus, sub, channel);
    // The request's time, read once: everything it stamps carries it
    // (request_time.zig).
    const now = requestTime(io);
    var call: Call = .{ .req = req, .io = io, .alloc = alloc, .bus = bus, .now = now };
    // **THE ROC'S MEMORY IS THE REQUEST'S**: it allocates on this request's
    // allocator itself (freed whole with the request: the kernel's request
    // heap, webbox's arena per request on Linux), with no arena over it, so
    // nothing it took outlives the request and nothing is taken twice.
    roc_chat.useRequest(alloc);
    const decision = try roc_chat.decide(alloc, sub, channel, req.head.method, call.host());
    // A failure the Roc could not be told (the store, reading who it is)
    // fails the request, as it did before the router.
    if (call.failed) |e| return e;
    if (decision != .redirect and !(decision == .serve and decision.serve.route.family == .asset) and !call.asked)
        std.debug.panic("the Roc router answered {f} without asking who is asking", .{decision});
    switch (decision) {
        .redirect => |location| return http.redirect(req, location),
        .serve => |s| {
            if (s.presence) presence.markActiveAndBroadcast(io, alloc, bus, call.uid, now);
            return chat.serve(req, io, alloc, bus, call.uid, s.route, now);
        },
        .respond => |r| {
            const headers = [_]std.http.Header{ .{ .name = "content-type", .value = r.content_type }, .{ .name = "x-content-type-options", .value = "nosniff" } };
            const n: usize = if (r.content_type.len == 0) 0 else if (r.nosniff) 2 else 1;
            return req.respond(r.body, .{ .status = @fromBackingInt(@intCast(r.status)), .extra_headers = headers[0..n] });
        },
        .not_allowed => |m| return http.methodNotAllowed(req, m),
        // The host answered inside the call (a body too big): nothing more.
        .answered => {},
        // The site's 400 for every malformed form (webbox site.zig).
        .malformed_form => return error.MalformedForm,
        .not_found => return http.notFound(req),
        .found => |location| return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = location }} }),
        // The host's bytes between the Roc's: a transcript (nothing around
        // it, so it goes out as read) or a page around rendered links.
        .held => |h| {
            const headers = [_]std.http.Header{ .{ .name = "content-type", .value = h.content_type }, .{ .name = "x-content-type-options", .value = "nosniff" } };
            const n: usize = if (h.content_type.len == 0) 0 else if (h.nosniff) 2 else 1;
            const body = if (h.before.len == 0 and h.after.len == 0) call.held else try std.mem.concat(alloc, u8, &.{ h.before, call.held, h.after });
            return req.respond(body, .{ .status = @fromBackingInt(@intCast(h.status)), .extra_headers = headers[0..n] });
        },
    }
}

/// **ONE REQUEST'S HOST, FOR ITS ROC CALL**: who is asking, read when the
/// Roc first asks, and the hosted functions the Roc's own routes call.
/// A failure is kept (`fail`), told to the Roc as "not done", and returned
/// by `handle` once the call has ended: a C call cannot carry a Zig error.
pub const Call = struct {
    req: *Request,
    io: Io,
    alloc: Alloc,
    bus: *Bus,
    now: Now,
    uid: []const u8 = "",
    asked: bool = false,
    /// The topic `topic` found, for the calls after it.
    found: ?chat.Found = null,
    /// The bytes a `held` answer carries (Host.raw!, Host.links!), read or
    /// rendered here and never copied into the Roc and out.
    held: []const u8 = "",
    failed: ?anyerror = null,

    pub fn host(c: *Call) roc_chat.Host {
        return .{
            .ctx = c,
            .member = member,
            .presence = presence_,
            .topic = topic,
            .body = body,
            .reactions = reactions_,
            .raw = raw,
            .links = links,
            .feed = feed,
            .recent = recentRows,
            .react = react,
            .pin = pin,
            .landing = landing,
            .page = page,
            .srcs = srcs,
            .me = me,
            .viewer = viewerName,
            .last_conv = lastConv,
            .resume_topic = resumeTopic,
            .topics = topics,
            .channels = channels,
            .members = members,
            .conv = conv,
            .bookmark = bookmark,
            .append = append,
            .send_conv = sendConv,
            .header = header,
            .hostile = hostile,
        };
    }

    fn of(ctx: *anyopaque) *Call {
        return @ptrCast(@alignCast(ctx));
    }

    fn fail(c: *Call, e: anyerror) void {
        c.failed = e;
    }

    /// **AFTER A FAILURE THE HOST DOES NOTHING MORE** for the call: every
    /// hosted function but `member` asks this first, and answers its empty
    /// or "failed" value, so a Roc that goes on writes nothing more.
    fn dead(c: *Call) bool {
        return c.failed != null;
    }

    pub fn member(ctx: *anyopaque) bool {
        const c = of(ctx);
        c.asked = true;
        // absent-ok: not read as absence: `fail` keeps the error, and handle returns it once the Roc call ends (a C call cannot carry it).
        c.uid = users.currentUserID(c.io, c.alloc, c.req) catch |e| {
            c.fail(e);
            return false;
        };
        // NEED_PASSWORD: the whole chat subsystem (DMs, docs, recent, images,
        // code, the conversations API) is members + agents only. A guest
        // (name-only, no password) or a stranger is sent to set a password and
        // returned here: guests may play the game, but chat requires
        // membership.
        // absent-ok: the same: the error is kept and returned, never read as "not a member".
        return users.principalAuthorized(c.io, c.alloc, c.uid) catch |e| {
            c.fail(e);
            return false;
        };
    }

    fn presence_(ctx: *anyopaque) void {
        const c = of(ctx);
        if (c.dead()) return;
        presence.markActiveAndBroadcast(c.io, c.alloc, c.bus, c.uid, c.now);
    }

    fn topic(ctx: *anyopaque, family: roc_chat.Family, key: []const u8, sid: []const u8) bool {
        const c = of(ctx);
        if (c.dead()) return false;
        const route: roc_chat.Route = .{ .family = family, .part = .topic, .key = c.alloc.dupe(u8, key) catch |e| return c.no(e), .sid = c.alloc.dupe(u8, sid) catch |e| return c.no(e) };
        // absent-ok: not read as absence: a failed lookup is kept and returned once the call ends; only "not found" is false.
        c.found = chat.findTopic(c.io, c.alloc, c.uid, route) catch |e| return c.no(e);
        return c.found != null;
    }

    /// `fail`, answering the Roc "not done".
    fn no(c: *Call, e: anyerror) bool {
        c.fail(e);
        return false;
    }

    fn body(ctx: *anyopaque, which: roc_chat.Form) ?[]const u8 {
        const c = of(ctx);
        if (c.dead()) return null;
        const limit: usize = switch (which) {
            .reaction => reactions.max_body_bytes,
            .message => limits.body.chat_message,
        };
        // Null when it answered 413 (or 400) itself.
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        return http.readLimitedBody(c.req, c.alloc, limit) catch |e| {
            c.fail(e);
            return null;
        };
    }

    fn reactions_(ctx: *anyopaque) ?[]const u8 {
        const c = of(ctx);
        if (c.dead()) return null;
        const t = c.found orelse @panic("Host.reactions!: no topic found");
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        return store.readReactions(c.io, c.alloc, t.dir, t.sid) catch |e| {
            c.fail(e);
            return null;
        };
    }

    /// The found topic's transcript, held for the answer: whether there is
    /// one.
    fn raw(ctx: *anyopaque) bool {
        const c = of(ctx);
        if (c.dead()) return false;
        const t = c.found orelse @panic("Host.raw!: no topic found");
        // absent-ok: not read as absence: a failed read is kept and returned once the call ends; only "no transcript" is none.
        c.held = (chat_paths.readTranscript(c.io, c.alloc, t.dir, t.sid) catch |e| return c.no(e)) orelse return false;
        return true;
    }

    /// The member's links.md, rendered as the server's own markdown
    /// (`renderTrusted`: a curated page has far more links than a message
    /// may), held for the answer: whether there is one.
    fn links(ctx: *anyopaque) bool {
        const c = of(ctx);
        if (c.dead()) return false;
        const path = std.fs.path.join(c.alloc, &.{ store.chat_root, "users", c.uid, "links.md" }) catch |e| return c.no(e);
        // absent-ok: the same; only "no file" is none.
        const md = (webbox.store.readOrNull(c.io, c.alloc, path, .unlimited) catch |e| return c.no(e)) orelse return false;
        c.held = markdown.renderTrusted(c.alloc, md) catch |e| return c.no(e);
        return true;
    }

    /// The member's recent feed as recent.zig gathers it, nine fields a row.
    fn recentRows(ctx: *anyopaque) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        // absent-ok: not read as absence: a failed read is kept and returned once the call ends.
        const rows = recent.gatherRows(c.io, c.alloc, c.uid) catch |e| return c.none(e);
        var out: std.ArrayList([]const u8) = .empty;
        for (rows) |w| {
            const secs = std.fmt.allocPrint(c.alloc, "{d}", .{w.secs}) catch |e| return c.none(e);
            out.appendSlice(c.alloc, &.{ if (w.doc) "1" else "0", secs, w.uid, w.name, w.key, w.label, w.topic, w.markdown, if (w.dm) "1" else "0" }) catch |e| return c.none(e);
        }
        return out.items;
    }

    /// The member's images.md or code.md, as stored, or none.
    fn feed(ctx: *anyopaque, which: roc_chat.Feed) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const name = switch (which) {
            .images => "images.md",
            .code => "code.md",
        };
        const path = std.fs.path.join(c.alloc, &.{ store.chat_root, "users", c.uid, name }) catch |e| return c.none(e);
        // absent-ok: not read as absence: a failed read is kept and returned once the call ends; only "no file" is none.
        const data = (webbox.store.readOrNull(c.io, c.alloc, path, .unlimited) catch |e| return c.none(e)) orelse return &.{};
        return c.alloc.dupe([]const u8, &.{data}) catch |e| c.none(e);
    }

    fn react(ctx: *anyopaque, msg: u64, emoji: []const u8, on: bool) roc_chat.Reacted {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const t = c.found orelse @panic("Host.react!: no topic found");
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        const done = reactions.storeReaction(c.io, c.alloc, c.bus, t.address(), c.uid, c.now, .{ .msg = msg, .emoji = emoji, .on = on }) catch |e| {
            c.fail(e);
            return .failed;
        };
        return switch (done) {
            .stored => .stored,
            .no_such_message => .no_such_message,
        };
    }

    fn pin(ctx: *anyopaque, pinned: bool) bool {
        const c = of(ctx);
        if (c.dead()) return false;
        const t = c.found orelse @panic("Host.pin!: no topic found");
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        chat_state.setTopicPinned(c.io, c.alloc, c.uid, t.key, t.sid, pinned) catch |e| return c.no(e);
        return true;
    }

    /// `fail`, answering the Roc nothing.
    fn none(c: *Call, e: anyerror) []const []const u8 {
        c.fail(e);
        return &.{};
    }

    fn landing(ctx: *anyopaque, family: roc_chat.Family, key_: []const u8) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const key = c.alloc.dupe(u8, key_) catch |e| return c.none(e);
        // absent-ok: not read as absence: a failed lookup is kept and returned once the call ends; only "not the member's" is none.
        const f = (chat.findConv(c.io, c.alloc, c.uid, family, key) catch |e| return c.none(e)) orelse return &.{};
        // absent-ok: the same.
        const first = chat_paths.firstTopic(c.io, c.alloc, f.dir) catch |e| return c.none(e);
        if (first.len > 0) return c.alloc.dupe([]const u8, &.{ f.base, first }) catch |e| c.none(e);
        // No topics yet: the page that offers the first reads the title (a
        // DM's partner) and the viewer, in that order, as the Zig did.
        // absent-ok: the same.
        const title = chat.convTitle(c.io, c.alloc, c.uid, f) catch |e| return c.none(e);
        // absent-ok: the same.
        const viewer = users.getUserName(c.io, c.alloc, c.uid) catch |e| return c.none(e);
        return c.alloc.dupe([]const u8, &.{ f.base, "", viewer, title }) catch |e| c.none(e);
    }

    fn page(ctx: *anyopaque) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const f = c.found orelse @panic("Host.page!: no topic found");
        return c.pageFields(f) catch |e| c.none(e);
    }

    /// The page's data in conversationPage's order: the resume pointer
    /// written (DMs), the viewer, the sidebar.
    fn pageFields(c: *Call, f: chat.Found) ![]const []const u8 {
        if (f.dm) try chat_state.setLastViewedTopic(c.io, c.alloc, c.uid, f.key, f.sid);
        const viewer = try users.getUserName(c.io, c.alloc, c.uid);
        const sidebar = try chat_page.sidebarOf(c.io, c.alloc, c.uid, try f.topic(c.alloc), c.now);
        var out: std.ArrayList([]const u8) = .empty;
        const n = struct {
            fn digits(a: Alloc, v: anytype) ![]const u8 {
                return std.fmt.allocPrint(a, "{d}", .{v});
            }
        }.digits;
        try out.appendSlice(c.alloc, &.{ viewer, f.title, try n(c.alloc, chat_upload.image_max), try n(c.alloc, chat_upload.video_max), chat_upload.accept, try n(c.alloc, @import("search_tokens.zig").min_len) });
        try out.appendSlice(c.alloc, try chat_page.sidebarFields(c.alloc, sidebar));
        return out.items;
    }

    fn srcs(ctx: *anyopaque) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        inline for (chrome.assets) |a| {
            const src = chrome.src(c.alloc, a.name) catch |e| return c.none(e);
            out.appendSlice(c.alloc, &.{ a.name, src }) catch |e| return c.none(e);
        }
        return out.items;
    }

    fn me(ctx: *anyopaque) []const u8 {
        return of(ctx).uid;
    }

    /// `fail`, answering the Roc "".
    fn nothing(c: *Call, e: anyerror) []const u8 {
        c.fail(e);
        return "";
    }

    fn viewerName(ctx: *anyopaque) []const u8 {
        const c = of(ctx);
        if (c.dead()) return "";
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        return users.getUserName(c.io, c.alloc, c.uid) catch |e| c.nothing(e);
    }

    fn lastConv(ctx: *anyopaque) []const u8 {
        const c = of(ctx);
        if (c.dead()) return "";
        // absent-ok: the same.
        return chat_state.lastUserConv(c.io, c.alloc, c.uid) catch |e| c.nothing(e);
    }

    fn resumeTopic(ctx: *anyopaque, conv_: []const u8) []const u8 {
        const c = of(ctx);
        if (c.dead()) return "";
        // absent-ok: the same.
        return chat_state.resumeTopic(c.io, c.alloc, c.uid, conv_, c.now) catch |e| c.nothing(e);
    }

    fn topics(ctx: *anyopaque, family: roc_chat.Family, key: []const u8) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const dir = switch (family) {
            .dm => chat_paths.dmConvDir(c.alloc, key),
            .channel => chat_paths.channelConvDir(c.alloc, key),
            else => std.debug.panic("Host.topics!: family {t}", .{family}),
        } catch |e| return c.none(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        return chat_paths.listTopics(c.io, c.alloc, dir) catch |e| c.none(e);
    }

    fn channels(ctx: *anyopaque) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        // absent-ok: the same.
        return chat_paths.listUserChannels(c.io, c.alloc, c.uid) catch |e| c.none(e);
    }

    fn members(ctx: *anyopaque) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        // absent-ok: the same.
        const all = users.listAuthorized(c.io, c.alloc) catch |e| return c.none(e);
        var out: std.ArrayList([]const u8) = .empty;
        for (all) |u| out.appendSlice(c.alloc, &.{ u.id, u.name }) catch |e| return c.none(e);
        return out.items;
    }

    fn conv(ctx: *anyopaque, family: roc_chat.Family, key_: []const u8) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const key = c.alloc.dupe(u8, key_) catch |e| return c.none(e);
        // absent-ok: not read as absence: a failed lookup is kept and returned once the call ends; only "not the member's" is none.
        const f = (chat.findConv(c.io, c.alloc, c.uid, family, key) catch |e| return c.none(e)) orelse return &.{};
        c.found = f;
        return c.alloc.dupe([]const u8, &.{ f.base, if (f.dm) "1" else "0" }) catch |e| c.none(e);
    }

    fn bookmark(ctx: *anyopaque, sid: []const u8) bool {
        const c = of(ctx);
        if (c.dead()) return false;
        const f = c.found orelse @panic("Host.bookmark!: no conversation found");
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        chat_state.setLastViewedTopic(c.io, c.alloc, c.uid, f.key, c.alloc.dupe(u8, sid) catch |e| return c.no(e)) catch |e| return c.no(e);
        return true;
    }

    fn append(ctx: *anyopaque, sid_: []const u8, name: []const u8, markdown_: []const u8, cid_: []const u8) bool {
        const c = of(ctx);
        if (c.dead()) return false;
        var f = c.found orelse @panic("Host.append!: no conversation found");
        f.sid = c.alloc.dupe(u8, sid_) catch |e| return c.no(e);
        const t = f.topic(c.alloc) catch |e| return c.no(e);
        const author: store.Author = .{ .name = c.alloc.dupe(u8, name) catch |e| return c.no(e), .id = c.uid };
        const md = c.alloc.dupe(u8, markdown_) catch |e| return c.no(e);
        const cid = c.alloc.dupe(u8, cid_) catch |e| return c.no(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        _ = store.appendMessage(c.io, c.alloc, c.bus, c.now, t.conv.meta, f.address(), author, md, cid) catch |e| return c.no(e);
        return true;
    }

    fn sendConv(ctx: *anyopaque, family: roc_chat.Family, key_: []const u8, sid: []const u8) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const key = c.alloc.dupe(u8, key_) catch |e| return c.none(e);
        // absent-ok: not read as absence: a failed lookup is kept and returned once the call ends; only "not the member's" is none.
        var f = (chat.findConv(c.io, c.alloc, c.uid, family, key) catch |e| return c.none(e)) orelse return &.{};
        f.sid = c.alloc.dupe(u8, sid) catch |e| return c.none(e);
        // The topic's title (a DM's partner read), as convRoute read it.
        // absent-ok: the same.
        f.title = chat.convTitle(c.io, c.alloc, c.uid, f) catch |e| return c.none(e);
        c.found = f;
        return c.alloc.dupe([]const u8, &.{ f.base, if (f.dm) "1" else "0" }) catch |e| c.none(e);
    }

    fn header(ctx: *anyopaque, name: []const u8) []const []const u8 {
        const c = of(ctx);
        if (c.dead()) return &.{};
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        const v = (http.header(c.req, c.alloc, name) catch |e| return c.none(e)) orelse return &.{};
        return c.alloc.dupe([]const u8, &.{v}) catch |e| c.none(e);
    }

    fn hostile(ctx: *anyopaque, md: []const u8) roc_chat.Hostility {
        const c = of(ctx);
        if (c.dead()) return .failed;
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        const reason = markdown.hostileReason(c.alloc, md) catch |e| {
            c.fail(e);
            return .failed;
        };
        if (reason == null) return .fine;
        // absent-ok: the same: a refusal that will not send is the request's failure.
        edge.reject(c.req, .malformed_markdown, "not sent: malformed markdown — too much formatting; break it into smaller messages\n") catch |e| c.fail(e);
        return .refused;
    }
};
