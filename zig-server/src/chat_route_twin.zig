//! **THE ROC ROUTER'S TWIN** (roc-webbox docs/ROC-CHAT.md A3): chat.zig's
//! dispatch as it was before the Roc router took it (`handle`,
//! `handleChannel`, `convRoute`, `topicRoute`, at angry-gopher 112349a),
//! kept as a pure function of the path, whether it is under /channel, and
//! whether the one asking is a member: what the old code decided before it
//! touched the disk or the viewer. The test below holds the Roc router to it
//! over a corpus; this file is test-only, and goes when the router has no
//! more to prove.

const std = @import("std");
const roc_chat = @import("roc_chat");
const chat_paths = @import("chat_paths.zig");
const Route = roc_chat.Route;
const Decision = roc_chat.Decision;

pub fn decide(alloc: std.mem.Allocator, sub: []const u8, channel: bool, member: bool) !Decision {
    if (!channel and sub.len > 1 and std.mem.endsWith(u8, sub, ".js"))
        return .{ .serve = .{ .route = .{ .family = .asset, .rest = sub[1..] }, .presence = false } };
    if (!member) return .{ .redirect = try std.fmt.allocPrint(alloc, "/login/full?next={s}{s}", .{ if (channel) "/channel" else "/chat", sub }) };
    const route = if (channel) underChannel(sub) else underChat(sub);
    return .{ .serve = .{ .route = route, .presence = !isStream(route) } };
}

/// **ONE CHANGE FROM THE OLD CODE, ON PURPOSE**: whether a request counts as
/// presence is read from its route. The old code read the path's spelling
/// (`endsWith "/stream"` or `/notifications`), so `.../general/stream/`, a
/// stream, counted as presence, and a topic named `stream`, a page, did not
/// (found by router.zig's hooks test, which this agreement made possible).
fn isStream(r: Route) bool {
    return r.tail == .stream or r.family == .notifications or r.family == .sidebar_stream or
        ((r.family == .recent or r.family == .images or r.family == .code) and std.mem.eql(u8, r.rest, "/stream"));
}

fn underChat(sub: []const u8) Route {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) return .{ .family = .default };
    inline for (.{ .{ "/docs", .docs }, .{ "/recent", .recent }, .{ "/images", .images }, .{ "/code", .code }, .{ "/links", .links } }) |f| {
        if (matchPrefix(sub, f[0])) |rest| {
            if (rest.len == 0 or rest[0] == '/') return .{ .family = f[1], .rest = rest };
        }
    }
    if (matchPrefix(sub, "/search")) |rest| return .{ .family = .search, .rest = rest };
    if (std.mem.eql(u8, sub, "/default")) return .{ .family = .default };
    if (std.mem.eql(u8, sub, "/conversations")) return .{ .family = .conversations };
    if (matchPrefix(sub, "/msg/")) |id| return .{ .family = .msg, .rest = id };
    if (matchPrefix(sub, "/c/")) |rest| return conversation(.dm, rest);
    if (std.mem.eql(u8, sub, "/notifications")) return .{ .family = .notifications };
    if (std.mem.eql(u8, sub, "/sidebar/stream")) return .{ .family = .sidebar_stream };
    return .{ .family = .not_found };
}

fn underChannel(sub: []const u8) Route {
    return conversation(.channel, sub);
}

fn conversation(family: roc_chat.Family, path: []const u8) Route {
    var segs = segments(path);
    const key = segs.next() orelse return .{ .family = .not_found };
    if (family == .channel and !chat_paths.validChannelName(key)) return .{ .family = .not_found };
    const sid = segs.next() orelse return .{ .family = family, .key = key };
    if (std.mem.eql(u8, sid, "new")) return .{ .family = family, .key = key, .part = .new };
    if (!chat_paths.validTopicID(sid)) return .{ .family = family, .key = key, .part = .invalid };
    var r: Route = .{ .family = family, .key = key, .topic = sid, .part = .topic };
    var peek = segs;
    const is_send = if (peek.next()) |t| std.mem.eql(u8, t, "send") else false;
    const tail = segs.next() orelse return r;
    if (std.mem.eql(u8, tail, "uploads")) {
        const file = segs.next() orelse return bad(r, is_send);
        if (segs.next() != null) return bad(r, is_send);
        r.tail = .uploads;
        r.rest = file;
        return r;
    }
    if (segs.next() != null) return bad(r, is_send);
    inline for (.{ "stream", "send", "upload", "pin", "unpin", "raw", "download", "saved", "reactions", "react" }) |t| {
        if (std.mem.eql(u8, tail, t)) {
            r.tail = @field(roc_chat.Tail, t);
            return r;
        }
    }
    return bad(r, is_send);
}

fn bad(r: Route, is_send: bool) Route {
    var b = r;
    b.tail = if (is_send) .invalid_send else .invalid;
    return b;
}

const SegIter = struct {
    rest: []const u8,
    fn next(self: *SegIter) ?[]const u8 {
        while (self.rest.len > 0 and self.rest[0] == '/') self.rest = self.rest[1..];
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, '/') orelse self.rest.len;
        const seg = self.rest[0..end];
        self.rest = self.rest[end..];
        return seg;
    }
};

fn segments(path: []const u8) SegIter {
    return .{ .rest = path };
}

fn matchPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

// ── the agreement (A3): the Roc router decides as this did ─────────────────

const testing = std.testing;

/// The files whose quoted /chat and /channel paths join the corpus: every
/// route test, and the router's own tables.
const quoted = [_][]const u8{
    @embedFile("router_chat_test.zig"),     @embedFile("router_edges_test.zig"),
    @embedFile("router_failures_test.zig"), @embedFile("router_search_test.zig"),
    @embedFile("router_admin_test.zig"),    @embedFile("router_games_test.zig"),
    @embedFile("router_identity_test.zig"), @embedFile("router_legacy_cookies_test.zig"),
    @embedFile("router_pages_test.zig"),    @embedFile("router_script_test.zig"),
    @embedFile("router.zig"),
};

/// Each `"/chat…"` or `"/channel…"` literal in `text`, its query dropped,
/// as the path under its area.
fn quotedPaths(alloc: std.mem.Allocator, text: []const u8, out: *std.ArrayList([2][]const u8)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "\"/")) |at| {
        const start = at + 1;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse break;
        i = end + 1;
        const lit = text[start..end];
        const path = lit[0 .. std.mem.indexOfScalar(u8, lit, '?') orelse lit.len];
        for ([_][]const u8{ "/chat", "/channel" }) |area| {
            if (std.mem.startsWith(u8, path, area)) {
                const sub = path[area.len..];
                if (sub.len == 0 or sub[0] == '/') try out.append(alloc, .{ area, sub });
            }
        }
    }
}

/// The corpus's paths under their area, for the router's own test of its
/// pre-turn hooks (router.zig).
pub fn corpus(alloc: std.mem.Allocator) ![][]const u8 {
    var subs: std.ArrayList([]const u8) = .empty;
    try generated(alloc, &subs);
    var lits: std.ArrayList([2][]const u8) = .empty;
    for (quoted) |text| try quotedPaths(alloc, text, &lits);
    for (lits.items) |l| try subs.append(alloc, l[1]);
    return subs.toOwnedSlice(alloc);
}

/// Generated paths: the families and their edges, and conversations from
/// keys, topic ids and tails, with slashes doubled and trailing.
fn generated(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    for ([_][]const u8{
        "",                "/",               "//",            "/default",         "/default/",
        "/docs",           "/docs/",          "/docs/new",     "/docsX",           "/docs//x",
        "/recent",         "/recent/stream",  "/recentX",      "/images",          "/images/stream",
        "/code",           "/code/stream",    "/codeX",        "/links",           "/links/",
        "/search",         "/searchX",        "/search/words", "/search/messages", "/conversations",
        "/conversations/", "/msg/",           "/msg/a_1",      "/msg",             "/notifications",
        "/notifications/", "/sidebar/stream", "/sidebar",      "/chat.js",         "/.js",
        "/a/b.js",         "/js",             "/x.jsx",        "/c/",              "/c",
        "/nope",           "/\xff",           "/msg/\xff\xfe", "/c/1_2/\xff/raw",  "/docs/\xc3\xa9",
    }) |s| try out.append(alloc, s);
    const keys = [_][]const u8{ "1_2", "2_1", "1_1", "ops", "a-b", "9ops", "x", "1__2", "\xff" };
    const sids = [_][]const u8{ "general", "ChitChat", "2026-10-25", "new", "bad_id", "-x", "x-", "a--b", "a-b", &@as([80]u8, @splat('x')), &@as([81]u8, @splat('x')), "\xff" };
    const tails = [_][]const u8{
        "",               "/",            "/stream", "/send",   "/upload", "/upload/",  "/uploads",
        "/uploads/a.png", "/uploads/a/b", "/pin",    "/unpin",  "/raw",    "/download", "/saved",
        "/reactions",     "/react",       "/nope",   "/send/x", "/raw/x",  "//raw",     "/stream/",
    };
    for (keys) |k| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "/{s}", .{k}));
        for (sids) |s| for (tails) |t| {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "/c/{s}/{s}{s}", .{ k, s, t }));
            try out.append(alloc, try std.fmt.allocPrint(alloc, "/{s}/{s}{s}", .{ k, s, t }));
        };
    }
}

test "the Roc router decides every corpus path as chat.zig's dispatch did, under both areas, member or not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var subs: std.ArrayList([]const u8) = .empty;
    try generated(a, &subs);
    var lits: std.ArrayList([2][]const u8) = .empty;
    for (quoted) |text| try quotedPaths(a, text, &lits);
    try testing.expect(lits.items.len > 50); // the route tests' paths were found
    for (lits.items) |l| try subs.append(a, l[1]);

    var compared: usize = 0;
    var differ: usize = 0;
    for (subs.items) |sub| for ([_]bool{ false, true }) |channel| for ([_]bool{ false, true }) |member| {
        var call = std.heap.ArenaAllocator.init(testing.allocator);
        defer call.deinit();
        roc_chat.use(call.allocator());
        var ask: roc_chat.Routing = .{ .member = member };
        var got = try roc_chat.decide(call.allocator(), sub, channel, .GET, ask.host());
        const want = try decide(call.allocator(), sub, channel, member);
        compared += 1;
        // A route the Roc serves itself (C4) counted presence itself, before
        // it found no topic and handed the route to Zig.
        if (got == .serve and ask.marked) got.serve.presence = true;
        // Asked exactly when the old code read who it was: all but a script.
        const old_asked = !(want == .serve and want.serve.route.family == .asset);
        // A route the Roc answers outright (C3: /chat, the conversations,
        // a message's link, a new topic; /chat/links, /chat/recent,
        // /chat/images and /chat/code but their streams) has no Zig route to agree with: its
        // parse is held by chat_actions_twin_test.zig's answers instead. It
        // must be one of those, and counted as presence.
        if (got != .serve and got != .redirect and want == .serve) {
            const r = want.serve.route;
            const own = r.family == .default or r.family == .conversations or r.family == .msg or r.family == .links or ((r.family == .recent or r.family == .images or r.family == .code) and !std.mem.eql(u8, r.rest, "/stream")) or ((r.family == .dm or r.family == .channel) and r.part == .new);
            if (own and ask.marked and ask.asked) continue;
        }
        if (!got.eql(want) or ask.asked != old_asked) {
            differ += 1;
            if (differ <= 10) std.debug.print("{s} \"{s}\" member={}: roc {f} (asked {}), zig {f}\n", .{ if (channel) "/channel" else "/chat", sub, member, got, ask.asked, want });
        }
    };
    if (differ > 0) {
        std.debug.print("{d} of {d} decisions differ\n", .{ differ, compared });
        return error.TestUnexpectedResult;
    }
    try testing.expect(compared > 5000);
}
