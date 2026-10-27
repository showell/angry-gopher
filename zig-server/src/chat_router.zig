//! **EVERY /chat AND /channel REQUEST, THROUGH THE ROC ROUTER** (roc-webbox
//! docs/ROC-CHAT.md §3, milestone 1): the Roc chat (`roc_chat`, its
//! chat/main.roc) runs the prelude and parses the path; chat.zig serves the
//! route it answers, once the Roc call has ended.
//!
//! The prelude is the Roc's: a static script is served to anyone; anyone
//! else must be a member or the agent, or is sent to sign in; and anything
//! but a stream counts as presence. Who is asking stays here: the Roc asks
//! (`Host.check_member!`), after the static scripts, so a script's request does no
//! identity reads, as before.
//!
//! **A TOPIC'S REACTIONS, REACT, PIN AND UNPIN ARE THE ROC'S** (C4): it
//! serves them itself, asking `Call` (below) for presence, the reads its
//! lookup of the conversation decides on (O2: every account, once, looked
//! up by the Roc; a channel's member file and the topics' folder by the
//! file primitives, named and parsed by the Roc), the body, who is online
//! and the limits the server enforces (a page's sidebar and its client's
//! caps, the rest of the page the Roc's), the
//! primitives a reaction and a message are stored and sent by (a line
//! appended, a topic's count, the markdown render, a message's block stored
//! with its count and search, the bus) and fanned out by (a message's parts
//! as the one markdown reader finds them, a feed's entry appended, a
//! surface that failed counted), and answers what to send. `handle` sends it once
//! the call has ended. **THE HOST HOLDS NO CONVERSATION BETWEEN CALLS**:
//! each operation on one is handed it (`roc_chat.Conv`) by the Roc.

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
const store = @import("chat_store.zig");
const chat_count = @import("chat_count.zig");
const chat_fanout = @import("chat_fanout.zig");
const chat_paths = @import("chat_paths.zig");
const chrome = @import("chat_chrome.zig");
const chat_upload = @import("chat_upload.zig");
const limits = @import("limits.zig");
const markdown = @import("markdown.zig");
const edge = webbox.edge;
const Now = @import("request_time.zig").Now;
const Conv = @import("chat_conv.zig").Conv;

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
    // A crash after a kept failure is that failure's: every hosted function
    // answers empty once one has failed, which the Roc may not survive.
    const decision = roc_chat.decide(alloc, sub, channel, req.head.method, call.host()) catch |e| return call.failed orelse e;
    // A failure the Roc could not be told (the store, reading who it is)
    // fails the request, as it did before the router.
    if (call.failed) |e| return e;
    if (decision != .redirect and !(decision == .serve and decision.serve.route.family == .asset) and !call.asked)
        std.debug.panic("the Roc router answered {f} without asking who is asking", .{decision});
    switch (decision) {
        // Built by the Roc from a conversation's base and a topic, which the
        // store's names keep on the site: one off it is a bug, the router's
        // 500, never a redirect somewhere else.
        .redirect => |location| return http.redirect(req, try http.Target.format(alloc, "{s}", .{location})),
        .to_login => |next| return toLogin(req, alloc, next),
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
        .found => |location| return http.redirectWith(req, try http.Target.format(alloc, "{s}", .{location}), .{ .status = .found }),
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

/// To the login page, to come back to `next` after (the Roc's gate,
/// chat/main.roc `dispatch!`): **the request's own path, so one that is no
/// path on this site is its 400** (metal-vmm QUEUE 250), never a redirect
/// to the root or anywhere else.
pub fn toLogin(req: *Request, alloc: Alloc, next: []const u8) !void {
    const back = http.Target.format(alloc, "/login/full?next={s}", .{next}) catch |e| switch (e) {
        error.NotOnSite => return req.respond("not a path on this site\n", .{ .status = .bad_request }),
        else => return e,
    };
    return http.redirect(req, back);
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
    /// The bytes a `held` answer carries (Host.serve_file!, Host.serve_rendered!), read or
    /// rendered here and never copied into the Roc and out.
    held: []const u8 = "",
    failed: ?anyerror = null,
    /// The accounts as `accounts` listed them, each read that failed kept
    /// with its error, for `failAccount`.
    listed: []const users.Account = &.{},

    pub fn host(c: *Call) roc_chat.Host {
        return .{
            .ctx = c,
            .check_member = checkMember,
            .count_presence = presence_,
            .list_accounts = accounts,
            .fail_account = failAccount,
            .read_body = body,
            .serve_file = serveFile,
            .serve_rendered = serveRendered,
            .gather_recent = recentRows,
            .publish = publish,
            .append_line = appendLine,
            .message_count = messageCount,
            .read = read,
            .write = write,
            .remove = remove,
            .list = list,
            .fail = refuse,
            .fail_text = failText,
            .count_malformed_channel = malformedChannel,
            .check_online = online,
            .limits = limits_,
            .srcs = srcs,
            .me = me,
            .now = now_,
            .render = render,
            .store_message = storeMessage,
            .append_entry = appendEntry,
            .report_fanout_failure = fanoutFailed,
            .read_header = header,
            .check_hostile = hostile,
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

    pub fn checkMember(ctx: *anyopaque) roc_chat.Membership {
        const c = of(ctx);
        c.asked = true;
        // absent-ok: not read as absence: `fail` keeps the error, and handle returns it once the Roc call ends (a C call cannot carry it).
        c.uid = users.currentUserID(c.io, c.alloc, c.req) catch |e| {
            c.fail(e);
            return .outsider;
        };
        // NEED_PASSWORD: the whole chat subsystem (DMs, docs, recent, images,
        // code, the conversations API) is members + agents only. A guest
        // (name-only, no password) or a stranger is sent to set a password and
        // returned here: guests may play the game, but chat requires
        // membership.
        // absent-ok: the same: the error is kept and returned, never read as "not a member".
        const authorized = users.principalAuthorized(c.io, c.alloc, c.uid) catch |e| {
            c.fail(e);
            return .outsider;
        };
        return if (authorized) .member else .outsider;
    }

    fn presence_(ctx: *anyopaque) void {
        const c = of(ctx);
        if (c.dead()) return;
        presence.markActiveAndBroadcast(c.io, c.alloc, c.bus, c.uid, c.now);
    }

    /// **EVERY ACCOUNT, THE ROC'S ONE IDENTITY READ** (Host.list_accounts!):
    /// users.listAccounts, which reads each canonical folder's password
    /// stat and name and nothing else of the auth root; the agent's kind is
    /// its. The Roc does every lookup (exists, a name, the roster) and asks
    /// at most once a request. A listing of the accounts that failed fails
    /// the request. **ONE ACCOUNT THAT WILL NOT READ DOES NOT**: it crosses
    /// as unreadable, its error kept (`listed`), and the request fails with
    /// that error only when the Roc's lookup needs it (`failAccount`), as
    /// the Zig's own lookups failed only when they read it.
    fn accounts(ctx: *anyopaque) roc_chat.Accounts {
        const c = of(ctx);
        if (c.dead()) return .failed;
        // absent-ok: not read as absence: a failed listing is kept and returned once the call ends.
        const all = users.listAccounts(c.io, c.alloc) catch |e| {
            c.fail(e);
            return .failed;
        };
        const out = c.alloc.alloc(roc_chat.Account, all.len) catch |e| {
            c.fail(e);
            return .failed;
        };
        for (all, out) |u, *o| o.* = .{
            .id = u.id,
            .kind = switch (u.kind) {
                .agent => .agent,
                .guest => .guest,
                .member => .member,
                .unreadable => .unreadable,
            },
            .name = switch (u.name) {
                .found => |n| .{ .found = n },
                .unreadable => .unreadable,
            },
        };
        c.listed = all;
        return .{ .found = out };
    }

    /// **THE REQUEST FAILS WITH THE ACCOUNT'S OWN ERROR** (Host.fail!,
    /// KindUnreadable or NameUnreadable): the error account `id`'s `which`
    /// read failed with when `accounts` listed it, the error the Zig's own
    /// lookup returned. An account not listed, or whose read did not fail,
    /// is the Roc's bug, and fails the request as error.AccountNotUnreadable,
    /// never served.
    fn failAccount(ctx: *anyopaque, which: roc_chat.AccountRead, id: []const u8) void {
        const c = of(ctx);
        if (c.dead()) return;
        for (c.listed) |u| {
            if (!std.mem.eql(u8, u.id, id)) continue;
            switch (which) {
                .kind => if (u.kind == .unreadable) return c.fail(u.kind.unreadable),
                .name => if (u.name == .unreadable) return c.fail(u.name.unreadable),
            }
            break;
        }
        c.fail(error.AccountNotUnreadable);
    }

    /// **THE CONVERSATION THE ROC FOUND, AS THE STORE TAKES IT**: where it
    /// is on disk (the one thing the host adds: a path), its kind and
    /// members, key and base as the Roc handed them, copied out of the
    /// Roc's memory (the store keeps some, live, past the call).
    fn resolved(c: *Call, conv: roc_chat.Conv) !Conv {
        const who = try c.alloc.alloc([]const u8, conv.members.len);
        for (conv.members, who) |m, *out| out.* = try c.alloc.dupe(u8, m);
        const key = try c.alloc.dupe(u8, conv.key);
        const kind: store.ConvKind, const dir = switch (conv.family) {
            .dm => .{ .dm, try chat_paths.dmConvDir(c.alloc, key) },
            .channel => .{ .channel, try chat_paths.channelConvDir(c.alloc, key) },
            else => std.debug.panic("a conversation of family {t}", .{conv.family}),
        };
        return .{ .meta = .{ .kind = kind, .members = who }, .key = key, .base = try c.alloc.dupe(u8, conv.base), .dir = dir };
    }

    /// Topic `sid_` of `conv`, as the store addresses it.
    fn address(c: *Call, conv: roc_chat.Conv, sid_: []const u8) !store.TopicAddress {
        const r = try c.resolved(conv);
        return .{ .dir = r.dir, .key = r.key, .sid = try c.alloc.dupe(u8, sid_) };
    }

    /// `fail`, answering the Roc "not done".
    fn no(c: *Call, e: anyerror) roc_chat.Done {
        c.fail(e);
        return .failed;
    }

    /// `fail`, answering the Roc `NotServing`.
    fn notServing(c: *Call, e: anyerror) roc_chat.Serving {
        c.fail(e);
        return .not_serving;
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

    /// The file at `path` under the chat root (Host.serve_file!: a topic's
    /// transcript, its name the Roc's; the seam has checked it), its bytes
    /// held for the answer: `.serving` when there is one.
    fn serveFile(ctx: *anyopaque, path: []const u8) roc_chat.Serving {
        const c = of(ctx);
        if (c.dead()) return .not_serving;
        // absent-ok: not read as absence: a failed read is kept and returned once the call ends; only "no file" is none.
        c.held = (c.heldFile(path) catch |e| return c.notServing(e)) orelse return .not_serving;
        return .serving;
    }

    /// The file at `path` under the chat root (Host.serve_rendered!: the member's
    /// links.md, its name the Roc's; the seam has checked it), rendered as
    /// the server's own markdown (`renderTrusted`: a curated page has far
    /// more links than a message may), held for the answer: `.serving`
    /// when there is one.
    fn serveRendered(ctx: *anyopaque, path: []const u8) roc_chat.Serving {
        const c = of(ctx);
        if (c.dead()) return .not_serving;
        // absent-ok: the same; only "no file" is none.
        const md = (c.heldFile(path) catch |e| return c.notServing(e)) orelse return .not_serving;
        c.held = markdown.renderTrusted(c.alloc, md) catch |e| return c.notServing(e);
        return .serving;
    }

    /// The file at `path` under the chat root, or null when it is not there.
    fn heldFile(c: *Call, path: []const u8) !?[]u8 {
        const p = try std.fs.path.join(c.alloc, &.{ store.chat_root, path });
        return webbox.store.readOrNull(c.io, c.alloc, p, .unlimited);
    }

    /// The member's recent feed as recent.zig gathers it.
    fn recentRows(ctx: *anyopaque) []const roc_chat.RecentRow {
        const c = of(ctx);
        if (c.dead()) return &.{};
        // absent-ok: not read as absence: a failed read is kept and returned once the call ends.
        const rows = recent.gatherRows(c.io, c.alloc, c.uid) catch |e| return c.noRecent(e);
        const out = c.alloc.alloc(roc_chat.RecentRow, rows.len) catch |e| return c.noRecent(e);
        for (rows, out) |w, *o| {
            const secs = std.fmt.allocPrint(c.alloc, "{d}", .{w.secs}) catch |e| return c.noRecent(e);
            o.* = .{ .kind = if (w.doc) .doc else .message, .secs = secs, .uid = w.uid, .name = w.name, .key = w.key, .label = w.label, .topic = w.topic, .markdown = w.markdown, .dm = if (w.dm) .dm else .channel };
        }
        return out;
    }

    /// `fail`, answering the Roc no recent rows.
    fn noRecent(c: *Call, e: anyerror) []const roc_chat.RecentRow {
        c.fail(e);
        return &.{};
    }

    /// **THE FILE PRIMITIVES** (Host.read!, Host.write!, Host.remove!,
    /// Host.list!): a file or folder under the chat root, its name and its
    /// format the Roc's (the member's bookmarks, pins and feeds: ChatState.roc,
    /// Feeds.roc; a conversation's topics, a channel's members, every
    /// roster, a topic's reactions: Paths.roc). The
    /// seam has refused a path that would leave the root (roc_chat
    /// `underRoot`); here it is only joined to it. Missing is nothing there
    /// (webbox.store.readOrNull: not found, or through a file); every other
    /// failure fails the request.
    fn read(ctx: *anyopaque, path: []const u8) roc_chat.Read {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const p = std.fs.path.join(c.alloc, &.{ store.chat_root, path }) catch |e| return c.unread(e);
        // absent-ok: not read as absence: a failed read is kept and returned once the call ends; only "no file" is missing.
        const data = (webbox.store.readOrNull(c.io, c.alloc, p, .unlimited) catch |e| return c.unread(e)) orelse return .missing;
        return .{ .found = data };
    }

    /// `fail`, answering the Roc that the read failed.
    fn unread(c: *Call, e: anyerror) roc_chat.Read {
        c.fail(e);
        return .failed;
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) roc_chat.Done {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const p = std.fs.path.join(c.alloc, &.{ store.chat_root, path }) catch |e| return c.no(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        webbox.store.write(c.io, c.alloc, p, bytes, .{}) catch |e| return c.no(e);
        return .ok;
    }

    fn remove(ctx: *anyopaque, path: []const u8) roc_chat.Done {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const p = std.fs.path.join(c.alloc, &.{ store.chat_root, path }) catch |e| return c.no(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends; a file not there is gone already.
        webbox.store.remove(c.io, c.alloc, p) catch |e| return c.no(e);
        return .ok;
    }

    /// **A FOLDER UNDER THE CHAT ROOT** (Host.list!): its entries as
    /// webbox.store.list gives them, in the disk's order. store.list holds a
    /// folder that is not there empty, and fails one that is a file (or
    /// through one: error.NotDir), which fails the request here, never read
    /// as nothing. An empty listing is told apart from a folder not there
    /// by `store.has`, so `.missing` means nothing there.
    fn list(ctx: *anyopaque, path: []const u8) roc_chat.Listing {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const p = std.fs.path.join(c.alloc, &.{ store.chat_root, path }) catch |e| return c.unlisted(e);
        // absent-ok: not read as absence: a failed listing is kept and returned once the call ends; only "no folder" is missing.
        const entries = webbox.store.list(c.io, c.alloc, p) catch |e| return c.unlisted(e);
        // absent-ok: the same.
        if (entries.len == 0 and !(webbox.store.has(c.io, c.alloc, p) catch |e| return c.unlisted(e))) return .missing;
        const out = c.alloc.alloc(roc_chat.Entry, entries.len) catch |e| return c.unlisted(e);
        for (entries, out) |e, *o| o.* = .{ .name = e.name, .kind = switch (e.kind) {
            .directory => .dir,
            .file => .file,
            .other => .other,
        } };
        return .{ .found = out };
    }

    /// `fail`, answering the Roc that the listing failed.
    fn unlisted(c: *Call, e: anyerror) roc_chat.Listing {
        c.fail(e);
        return .failed;
    }

    /// The seam's failure of the request (a path outside the chat root), and
    /// the Roc's own (Host.fail!: a malformed channel on its own route):
    /// kept as every hosted function's is, the first one kept.
    fn refuse(ctx: *anyopaque, e: anyerror) void {
        const c = of(ctx);
        if (!c.dead()) c.fail(e);
    }

    /// **A FILE THAT IS NOT TEXT FAILS THE REQUEST** (Host.fail!'s
    /// `NotUtf8`): the Roc's door refused the bytes of the file at `path`,
    /// a damaged file, never one the chat wrote; said with its path, and
    /// kept as every failure is.
    fn failText(ctx: *anyopaque, path: []const u8) void {
        const c = of(ctx);
        if (c.dead()) return;
        std.log.warn("chat: {s} is not UTF-8", .{path});
        c.fail(error.NotUtf8);
    }

    /// A channel the Roc's listing skipped as malformed, counted for
    /// /admin/host (chat_paths.countMalformed: the operator's count, kept
    /// for the process's life).
    fn malformedChannel(ctx: *anyopaque, name_: []const u8) void {
        const c = of(ctx);
        if (c.dead()) return;
        chat_paths.countMalformed(name_);
    }

    /// **THE BUS, AS A PRIMITIVE** (Host.publish!): webbox's bus.publish,
    /// which copies the bytes to each subscriber, so the Roc's go with the
    /// call. It cannot fail; after a failure it sends nothing.
    fn publish(ctx: *anyopaque, key: []const u8, bytes: []const u8) void {
        const c = of(ctx);
        if (c.dead()) return;
        c.bus.publish(key, bytes);
    }

    /// **ONE LINE APPENDED** (Host.append_line!): chat_store.appendLine,
    /// under the chat root (the seam has refused a path that would leave
    /// it), its torn-line rule the store's.
    fn appendLine(ctx: *anyopaque, path: []const u8, line: []const u8) roc_chat.Done {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const p = std.fs.path.join(c.alloc, &.{ store.chat_root, path }) catch |e| return c.no(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        store.appendLine(c.io, c.alloc, p, line) catch |e| return c.no(e);
        return .ok;
    }

    /// **A TOPIC'S MESSAGE COUNT** (Host.message_count!): chat_count's,
    /// its cache and its recount the store's, shared with the append. A
    /// count that failed fails the request, never 0.
    fn messageCount(ctx: *anyopaque, conv_: roc_chat.Conv, sid: []const u8) roc_chat.Count {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const t = c.address(conv_, sid) catch |e| return c.uncounted(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        return .{ .counted = chat_count.messageCount(c.io, c.alloc, t.dir, t.sid) catch |e| return c.uncounted(e) };
    }

    /// `fail`, answering the Roc that the count failed.
    fn uncounted(c: *Call, e: anyerror) roc_chat.Count {
        c.fail(e);
        return .failed;
    }

    /// `fail`, answering the Roc nothing.
    fn none(c: *Call, e: anyerror) []const []const u8 {
        c.fail(e);
        return &.{};
    }

    /// **WHO IS ONLINE, AT THE REQUEST'S TIME** (Host.check_online!, asked by the
    /// seam id by id): presence.isOnline, a read of presence's
    /// process-lifetime map at the request's `now`. It cannot fail; after
    /// a failure of the request it answers offline, reading nothing.
    pub fn online(ctx: *anyopaque, id: []const u8) roc_chat.Presence {
        const c = of(ctx);
        if (c.dead()) return .offline;
        return if (presence.isOnline(id, c.now)) .online else .offline;
    }

    /// **THE LIMITS THE SERVER ENFORCES** (Host.limits!): the upload's and
    /// the search's own constants, single-sourced here, which the
    /// conversation page tells its client. After a failure, nothing.
    fn limits_(ctx: *anyopaque) roc_chat.Limits {
        const c = of(ctx);
        if (c.dead()) return .{ .image_max = 0, .video_max = 0, .accept = "", .search_min = 0 };
        return .{ .image_max = chat_upload.image_max, .video_max = chat_upload.video_max, .accept = chat_upload.accept, .search_min = @import("search_tokens.zig").min_len };
    }

    fn srcs(ctx: *anyopaque) []const roc_chat.Src {
        const c = of(ctx);
        if (c.dead()) return &.{};
        const out = c.alloc.alloc(roc_chat.Src, chrome.assets.len) catch |e| return c.noSrcs(e);
        inline for (chrome.assets, 0..) |a, k| {
            out[k] = .{ .name = a.name, .src = chrome.src(c.alloc, a.name) catch |e| return c.noSrcs(e) };
        }
        return out;
    }

    /// `fail`, answering the Roc no scripts.
    fn noSrcs(c: *Call, e: anyerror) []const roc_chat.Src {
        c.fail(e);
        return &.{};
    }

    fn me(ctx: *anyopaque) []const u8 {
        return of(ctx).uid;
    }

    fn now_(ctx: *anyopaque) i64 {
        const c = of(ctx);
        if (c.dead()) return 0;
        return c.now.unixSecs();
    }

    /// **THE ONE MARKDOWN PROCESSOR** (Host.render!): a message's
    /// markdown as its frame's HTML, rendered once, before the store. A
    /// render that failed fails the request.
    fn render(ctx: *anyopaque, md: []const u8) roc_chat.Rendered {
        const c = of(ctx);
        if (c.dead()) return .failed;
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        return .{ .rendered = markdown.render(c.alloc, md) catch |e| {
            c.fail(e);
            return .failed;
        } };
    }

    /// The Roc's message as the store keeps it, its bytes copied out of
    /// the Roc's memory (the search index keeps some past the call).
    fn chatMessage(c: *Call, m: roc_chat.Message) !store.ChatMessage {
        return .{
            .id = try c.alloc.dupe(u8, m.id),
            .from = try c.alloc.dupe(u8, m.from),
            .at = try c.alloc.dupe(u8, m.at),
            .uid = try c.alloc.dupe(u8, m.uid),
            .markdown = try c.alloc.dupe(u8, m.markdown),
        };
    }

    /// **A MESSAGE STORED** (Host.store_message!): chat_store.storeMessage,
    /// the block the Roc made appended to the topic's transcript, then the
    /// count cache and the search index told. An append that failed fails
    /// the request, nothing stored.
    fn storeMessage(ctx: *anyopaque, conv_: roc_chat.Conv, sid: []const u8, block: []const u8, index: u64, m: roc_chat.Message) roc_chat.Done {
        const c = of(ctx);
        if (c.dead()) return .failed;
        const t = c.address(conv_, sid) catch |e| return c.no(e);
        const msg = c.chatMessage(m) catch |e| return c.no(e);
        // absent-ok: not read as absence: the error is kept and returned once the call ends.
        store.storeMessage(c.io, c.alloc, t, block, index, msg) catch |e| return c.no(e);
        return .ok;
    }

    /// **THE FAN-OUT'S PRIMITIVES NEVER FAIL THE REQUEST** (metal-vmm QUEUE
    /// 172, 156(c)): the Roc fans a message out after its store, and
    /// **STORED IS DONE**. Each failure goes back to the Roc as its error,
    /// which the Roc counts for one member's one surface (`fanoutFailed`),
    /// never kept by `fail`. After a failure of the request (none can follow
    /// a store) each answers that failure, doing nothing.
    /// **A FEED'S ENTRY APPENDED** (Host.append_entry!): as images_store
    /// `appendImagesEntry` and code_store `appendCodeEntry` append theirs,
    /// the entry's bytes the Roc's. The file is read only to decide whether
    /// the separator goes first; a read that fails is the append's failure,
    /// as it was theirs. The seam has refused a path outside the chat root.
    fn appendEntry(ctx: *anyopaque, path: []const u8, separator: []const u8, entry: []const u8) roc_chat.Appended {
        const c = of(ctx);
        if (c.failed) |e| return .{ .failed = e };
        c.appendedEntry(path, separator, entry) catch |e| return .{ .failed = e };
        return .appended;
    }

    fn appendedEntry(c: *Call, path: []const u8, separator: []const u8, entry: []const u8) !void {
        const p = try std.fs.path.join(c.alloc, &.{ store.chat_root, path });
        const existing = try webbox.store.readOrEmpty(c.io, c.alloc, p, .unlimited);
        const bytes = if (existing.len > 0) try std.mem.concat(c.alloc, u8, &.{ separator, entry }) else entry;
        _ = try webbox.store.append(c.io, c.alloc, p, bytes);
    }

    /// **A SURFACE THAT FAILED FOR ONE MEMBER, COUNTED AND SAID**
    /// (Host.report_fanout_failure!): chat_fanout.fanoutFailed, the operator's count
    /// and last failure on /admin/host, in its words: "<surface> for member
    /// <uid>, <error>, on <key>/<sid>".
    fn fanoutFailed(ctx: *anyopaque, surface: roc_chat.Surface, member_: []const u8, key: []const u8, sid: []const u8, e: anyerror) void {
        const c = of(ctx);
        if (c.dead()) return;
        chat_fanout.fanoutFailed(@tagName(surface), member_, e, key, sid);
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
