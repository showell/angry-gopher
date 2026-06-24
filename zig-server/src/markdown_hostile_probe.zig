// Diagnostic probe for the "hostile input" policy — NOT a gate. Two questions:
//
//  1. DISTRIBUTION: how close does REAL chat traffic get to the 256 markup-token
//     cap? (If real messages crowd the cap, it's producing false rejections; if
//     they're nowhere near it, it isn't guarding against anything real either.)
//
//  2. EARNED-KNOWLEDGE AUDIT: do the documented O(n²) adversarial shapes actually
//     stay LINEAR thanks to the monotonic cursors? We render each shape at
//     growing N via renderTrusted (which BYPASSES the markup cap, so we see the
//     parser's true scaling) and watch ns/byte. Flat ns/byte ⇒ linear ⇒ the cap
//     is a density relic, not a CPU guard. A rising ns/byte ⇒ a real re-parse
//     the cursors miss — the parser isn't using its earned knowledge.
//
// Run: cd zig-server && zig run src/markdown_hostile_probe.zig
const std = @import("std");
const markdown = @import("markdown.zig");
const chat_store = @import("chat_store.zig");
const Io = std.Io;

const CHAT_DIR_CANDIDATES = [_][]const u8{
    "/home/steve/AngryGopher/prod/chat",
    "/home/steve/AngryGopher/local/chat",
    "/tmp/prod-backup/prod/chat",
};

fn resolveChatDir(io: Io) ?[]const u8 {
    for (CHAT_DIR_CANDIDATES) |cand| {
        var dir = Io.Dir.cwd().openDir(io, cand, .{ .iterate = true }) catch continue;
        dir.close(io);
        return cand;
    }
    return null;
}

fn collectMd(io: Io, alloc: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const in_sessions = std.mem.eql(u8, std.fs.path.basename(dir_path), "sessions");
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        if (entry.kind == .directory) {
            try collectMd(io, alloc, child, out);
        } else if (in_sessions and std.mem.endsWith(u8, entry.name, ".md")) {
            try out.append(alloc, child);
        }
    }
}

const Rec = struct { id: []const u8, bytes: usize, tokens: usize };

fn mostTokens(_: void, a: Rec, b: Rec) bool {
    return a.tokens > b.tokens;
}

// ── part 2: synthetic adversarial shapes ────────────────────────────────────
const Shape = struct { name: []const u8, unit: []const u8 };
const SHAPES = [_]Shape{
    .{ .name = "open-brackets  [[[[", .unit = "[" },
    .{ .name = "link-bait      [](", .unit = "[](" },
    .{ .name = "emph-underscore a_b_", .unit = "a_b_" },
    .{ .name = "emph-star      ****", .unit = "*" },
    .{ .name = "backticks      ````", .unit = "`" },
    .{ .name = "angle-brackets <<<<", .unit = "<" },
    .{ .name = "nested-quote   > > ", .unit = "> " },
    .{ .name = "msg-ref-bait   MSG_a_1 ", .unit = "MSG_a_1 " },
    .{ .name = "dense-legit    **x** ", .unit = "**x** " },
};
const NS = [_]usize{ 2048, 4096, 8192, 16384, 32768, 65536 };

fn buildInput(alloc: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    const buf = try alloc.alloc(u8, n);
    for (buf, 0..) |*c, i| c.* = unit[i % unit.len];
    return buf;
}

fn timeRender(io: Io, arena: *std.heap.ArenaAllocator, md: []const u8) !u64 {
    var best: u64 = std.math.maxInt(u64);
    var b: usize = 0;
    while (b < 5) : (b += 1) {
        const t0 = Io.Clock.now(.awake, io);
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            _ = arena.reset(.retain_capacity);
            _ = try markdown.renderTrusted(arena.allocator(), md); // bypasses the markup cap
        }
        const t1 = Io.Clock.now(.awake, io);
        const per: u64 = @intCast(@divTrunc(t0.durationTo(t1).nanoseconds, 3));
        if (per < best) best = per;
    }
    return best;
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // ── part 1: real-corpus token distribution ──────────────────────────────
    const huge = std.math.maxInt(usize);
    if (resolveChatDir(io)) |chat_dir| {
        var files: std.ArrayList([]const u8) = .empty;
        try collectMd(io, alloc, chat_dir, &files);
        var recs: std.ArrayList(Rec) = .empty;
        var buckets = [_]usize{0} ** 4; // >64, >128, >192, >256
        const thresholds = [_]usize{ 64, 128, 192, 256 };
        for (files.items) |path| {
            const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch continue;
            const msgs = try chat_store.decodeChatFile(alloc, data);
            for (msgs) |m| {
                const tk = markdown.countMarkupTokens(m.markdown, huge);
                try recs.append(alloc, .{ .id = m.id, .bytes = m.markdown.len, .tokens = tk });
                for (thresholds, 0..) |t, bi| if (tk > t) {
                    buckets[bi] += 1;
                };
            }
        }
        std.mem.sort(Rec, recs.items, {}, mostTokens);
        std.debug.print("== part 1: markup-token distribution over {d} real messages\n", .{recs.items.len});
        std.debug.print("   cap = 256.  messages over: >64:{d}  >128:{d}  >192:{d}  >256:{d}\n", .{ buckets[0], buckets[1], buckets[2], buckets[3] });
        std.debug.print("   top markup-token messages (tokens / bytes / id):\n", .{});
        const top = @min(@as(usize, 8), recs.items.len);
        for (recs.items[0..top]) |r| {
            std.debug.print("     {d:5} tok  {d:6} B   {s}\n", .{ r.tokens, r.bytes, r.id });
        }
    } else {
        std.debug.print("(part 1 skipped: no corpus root found)\n", .{});
    }

    // ── part 2: linearity audit ─────────────────────────────────────────────
    std.debug.print("\n== part 2: earned-knowledge audit — ns/byte vs N (flat = linear)\n", .{});
    std.debug.print("   {s:<24}", .{"shape \\ N"});
    for (NS) |n| std.debug.print("{d:>7}", .{n});
    std.debug.print("\n", .{});
    for (SHAPES) |s| {
        std.debug.print("   {s:<24}", .{s.name});
        for (NS) |n| {
            const md = try buildInput(alloc, s.unit, n);
            defer alloc.free(md);
            const ns = try timeRender(io, &arena, md);
            const ns_per_byte = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
            std.debug.print("{d:>7.1}", .{ns_per_byte});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("   (cells are ns/byte; a column rising faster than flat = super-linear)\n", .{});
}
