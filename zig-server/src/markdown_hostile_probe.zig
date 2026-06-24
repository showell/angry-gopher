// Diagnostic probe for the render WORK BUDGET — NOT a gate. The budget
// (markdown_text.Budget) caps real parse work at `per_byte * bytes + base`
// work-units; this measures the actual work-units the parser charges, to:
//
//  1. TUNE per_byte — find the densest legit message's work/byte ratio over the
//     real corpus, so the ceiling sits with generous headroom above it (only
//     super-linear work should ever blow it), and
//  2. AUDIT earned knowledge — render the documented O(n²) adversarial shapes at
//     growing N and confirm work/byte stays FLAT (linear). A rising column would
//     be a re-parse the cursors miss.
//
// Work-units are deterministic (markdown.workUnits), so this is a stable signal,
// not wall-time. Run: cd zig-server && zig run src/markdown_hostile_probe.zig
const std = @import("std");
const markdown = @import("markdown.zig");
const chat_store = @import("chat_store.zig");
const mtext = @import("markdown_text.zig");
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

const Rec = struct { id: []const u8, bytes: usize, work: usize, ratio: f64 };

fn worstRatio(_: void, a: Rec, b: Rec) bool {
    return a.ratio > b.ratio;
}

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

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ── part 1: real-corpus work/byte distribution (tunes Budget.per_byte) ───
    if (resolveChatDir(io)) |chat_dir| {
        var files: std.ArrayList([]const u8) = .empty;
        try collectMd(io, alloc, chat_dir, &files);
        var recs: std.ArrayList(Rec) = .empty;
        var would_trip: usize = 0;
        for (files.items) |path| {
            const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch continue;
            const msgs = try chat_store.decodeChatFile(alloc, data);
            for (msgs) |m| {
                if (m.markdown.len == 0) continue;
                const w = try markdown.workUnits(alloc, m.markdown);
                const ratio = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(m.markdown.len));
                try recs.append(alloc, .{ .id = m.id, .bytes = m.markdown.len, .work = w, .ratio = ratio });
                if (w > mtext.Budget.per_byte * m.markdown.len + mtext.Budget.base) would_trip += 1;
            }
        }
        std.mem.sort(Rec, recs.items, {}, worstRatio);
        std.debug.print("== part 1: work/byte over {d} real messages\n", .{recs.items.len});
        std.debug.print("   current ceiling = {d}*bytes + {d}.  messages that would TRIP it: {d}\n", .{ mtext.Budget.per_byte, mtext.Budget.base, would_trip });
        std.debug.print("   densest by work/byte (work / bytes / ratio / id):\n", .{});
        const top = @min(@as(usize, 8), recs.items.len);
        for (recs.items[0..top]) |r| {
            std.debug.print("     {d:6} w  {d:6} B  {d:6.2} w/B   {s}\n", .{ r.work, r.bytes, r.ratio, r.id });
        }
    } else {
        std.debug.print("(part 1 skipped: no corpus root found)\n", .{});
    }

    // ── part 2: earned-knowledge audit — work/byte vs N (flat = linear) ──────
    std.debug.print("\n== part 2: work/byte vs N (deterministic; flat = linear)\n", .{});
    std.debug.print("   {s:<24}", .{"shape \\ N"});
    for (NS) |n| std.debug.print("{d:>8}", .{n});
    std.debug.print("\n", .{});
    for (SHAPES) |s| {
        std.debug.print("   {s:<24}", .{s.name});
        for (NS) |n| {
            const md = try buildInput(alloc, s.unit, n);
            defer alloc.free(md);
            const w = try markdown.workUnits(alloc, md);
            const ratio = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(n));
            std.debug.print("{d:>8.2}", .{ratio});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("   (cells are work-units/byte; a rising column = super-linear)\n", .{});
}
