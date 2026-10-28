//! **THE ROC ROUTER, PINNED** (roc-webbox docs/ROC-CHAT.md A3; metal-vmm
//! QUEUE 263b): the router's decisions over a corpus of paths, frozen as
//! goldens from the Roc itself, through the real ABI, on the day they
//! agreed with chat.zig's old dispatch (the twin that held them, retired):
//! `chat_route_golden.txt`, one line a decision, for a member, in both
//! areas. What a rule says better than a golden is a rule, over the whole
//! corpus: a path that is not UTF-8 is the door's 400, nothing asked; one
//! who is no member is sent to sign in and back to the request's own path,
//! but for a script. Test-only. The corpus also feeds router.zig's test of
//! its pre-turn hooks.
//!
//! A golden that differs writes what the Roc gave to
//! `.zig-cache/chat_route_golden.got.txt`, and fails. After a deliberate
//! change to the router, read its diff against the golden, then copy it over.

const std = @import("std");
const roc_chat = @import("roc_chat");
const Decision = roc_chat.Decision;

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

/// The golden's paths: the fixed ones, each tail of a conversation under a
/// spread of keys and topics (the topic past 80 bytes under one key), and
/// every path the route tests quote; each once, and only text (a path that
/// is not UTF-8 is the rule's, below).
fn reduced(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var all: std.ArrayList([]const u8) = .empty;
    try generated(alloc, &all);
    for (all.items[0..45]) |s| try out.append(alloc, s);
    const keys = [_][]const u8{ "1_2", "2_1", "ops", "1__2" };
    const sids = [_][]const u8{ "general", "bad_id", &@as([81]u8, @splat('x')), "new" };
    const tails = [_][]const u8{
        "",               "/",            "/stream", "/send",   "/upload", "/upload/",  "/uploads",
        "/uploads/a.png", "/uploads/a/b", "/pin",    "/unpin",  "/raw",    "/download", "/saved",
        "/reactions",     "/react",       "/nope",   "/send/x", "/raw/x",  "//raw",     "/stream/",
    };
    for (keys) |k| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "/{s}", .{k}));
        for (sids) |s| for (tails) |t| {
            // The topic past 80 bytes, under one key: the limit is the topic's.
            if (s.len > 80 and !std.mem.eql(u8, k, "1_2")) continue;
            try out.append(alloc, try std.fmt.allocPrint(alloc, "/c/{s}/{s}{s}", .{ k, s, t }));
            try out.append(alloc, try std.fmt.allocPrint(alloc, "/{s}/{s}{s}", .{ k, s, t }));
        };
    }
    var lits: std.ArrayList([2][]const u8) = .empty;
    for (quoted) |text| try quotedPaths(alloc, text, &lits);
    for (lits.items) |l| try out.append(alloc, l[1]);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var w: usize = 0;
    for (out.items) |s| {
        if (!std.unicode.utf8ValidateSlice(s) or (try seen.getOrPut(alloc, s)).found_existing) continue;
        out.items[w] = s;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
}

/// A decision as the golden says it: a page's status and type, never its
/// bytes (the router's work is where a request goes, not what a page
/// holds), and a route without its empty fields.
fn said(alloc: std.mem.Allocator, d: Decision) ![]const u8 {
    return switch (d) {
        .respond => |r| std.fmt.allocPrint(alloc, "{d} {s}", .{ r.status, r.content_type }),
        .held => |h| std.fmt.allocPrint(alloc, "held {d} {s}", .{ h.status, h.content_type }),
        else => blk: {
            var s = try std.fmt.allocPrint(alloc, "{f}", .{d});
            for ([_][]const u8{ " key=\"\"", " rest=\"\"", " topic=\"\"" }) |empty| s = try std.mem.replaceOwned(u8, alloc, s, empty, "");
            break :blk s;
        },
    };
}

test "the Roc router decides every golden path as it was frozen: the decision, and whether it asked who was asking and counted presence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var subs: std.ArrayList([]const u8) = .empty;
    try reduced(a, &subs);
    var got: std.ArrayList(u8) = .empty;
    for (subs.items) |sub| for ([_]bool{ false, true }) |channel| {
        var call = std.heap.ArenaAllocator.init(testing.allocator);
        defer call.deinit();
        roc_chat.use(call.allocator());
        var ask: roc_chat.Routing = .{ .member = true };
        const d = try roc_chat.decide(call.allocator(), sub, channel, .GET, ask.host());
        try got.print(a, "{s}\t\"{f}\"\t{s}\t{s}{s}\n", .{ if (channel) "/channel" else "/chat", std.zig.fmtString(sub), try said(a, d), if (ask.asked) "a" else "-", if (ask.marked) "m" else "-" });
    };
    const want = @embedFile("chat_route_golden.txt");
    if (std.mem.eql(u8, got.items, want)) return;
    std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ".zig-cache/chat_route_golden.got.txt", .data = got.items }) catch {};
    std.debug.print("the Roc's decisions differ from chat_route_golden.txt: .zig-cache/chat_route_golden.got.txt has them\n", .{});
    var g = std.mem.splitScalar(u8, got.items, '\n');
    var w = std.mem.splitScalar(u8, want, '\n');
    var shown: usize = 0;
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = g.next();
        const y = w.next();
        if (x == null and y == null) break;
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?)) continue;
        shown += 1;
        if (shown <= 10) std.debug.print("line {d}:\n  roc  {s}\n  want {s}\n", .{ line, x orelse "(none)", y orelse "(none)" });
    }
    return error.TestUnexpectedResult;
}

test "the router's rules over the whole corpus: a path that is not UTF-8 is the door's 400 with nothing asked; one who is no member signs in and comes back to the path, but for a script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subs = try corpus(a);
    try testing.expect(subs.len * 4 > 5000); // decisions: each path in both areas, member or not
    var differ: usize = 0;
    for (subs) |sub| for ([_]bool{ false, true }) |channel| for ([_]bool{ false, true }) |member| {
        var call = std.heap.ArenaAllocator.init(testing.allocator);
        defer call.deinit();
        roc_chat.use(call.allocator());
        var ask: roc_chat.Routing = .{ .member = member };
        const d = try roc_chat.decide(call.allocator(), sub, channel, .GET, ask.host());
        const area = if (channel) "/channel" else "/chat";
        const script = !channel and sub.len > 1 and std.mem.endsWith(u8, sub, ".js");
        const ok = if (!std.unicode.utf8ValidateSlice(sub))
            d == .malformed_form and !ask.asked and !ask.marked
        else if (script)
            d == .serve and d.serve.route.family == .asset and !ask.asked
        else if (!member)
            d == .to_login and std.mem.eql(u8, d.to_login, try std.mem.concat(call.allocator(), u8, &.{ area, sub })) and ask.asked
        else
            true;
        if (!ok) {
            differ += 1;
            if (differ <= 10) std.debug.print("{s} \"{f}\" member={}: {f} (asked {})\n", .{ area, std.zig.fmtString(sub), member, d, ask.asked });
        }
    };
    try testing.expectEqual(@as(usize, 0), differ);
}
