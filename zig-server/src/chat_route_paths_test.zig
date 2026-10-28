//! The paths the Roc router's tests run over (chat_route_corpus_test.zig's
//! goldens and rules, and chat_twin_test.zig's check of the pre-turn
//! hooks): every quoted /chat and /channel path in the route tests,
//! generated ones, and reduced forms of each. Test-only.

const std = @import("std");

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
pub fn reduced(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
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
