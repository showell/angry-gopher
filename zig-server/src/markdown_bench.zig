const std = @import("std");
const markdown = @import("markdown.zig");
const chat_store = @import("chat_store.zig");
const Io = std.Io;

// Diagnostic timing probe for the markdown renderer over the REAL prod chat
// corpus — NOT a gate, a measuring stick. It walks every chat transcript under
// CHAT_DIR, splits each into messages with the real decoder
// (chat_store.decodeChatFile), and times markdown.render on each message body.
// Reports corpus size, average message length, average render time, and the
// slowest individual messages — the starting point for hunting renderer
// weaknesses.
//
// Locally:   cd zig-server && zig run src/markdown_bench.zig
// On a host without a toolchain (the droplet): compile a static binary down
// here and ship it, exactly like the main server —
//   cd zig-server && zig build-exe src/markdown_bench.zig -femit-bin=markdown_bench
//   rsync markdown_bench steve@<droplet>:/tmp/ && ssh steve@<droplet> /tmp/markdown_bench
//
// The corpus root differs by machine, so instead of a runtime flag (a knob a
// benchmark shouldn't have) we bake a fixed search list and use the FIRST that
// exists — the chosen root is printed, so the run is self-describing. The
// transcripts embed real user messages (like gold.jsonl), so every candidate
// lives outside the repo. To bench a fresh backup locally, expand it under the
// last entry: mkdir -p /tmp/prod-backup && tar -xzf <backup>.tar.gz -C /tmp/prod-backup
const CHAT_DIR_CANDIDATES = [_][]const u8{
    "/home/steve/AngryGopher/prod/chat", // droplet prod data_dir/chat
    "/home/steve/AngryGopher/local/chat", // local dev data_dir/chat
    "/tmp/prod-backup/prod/chat", // a locally-expanded prod backup tarball
};

// Each message is timed in BATCHES batches of BATCH_RENDERS renders. One
// monotonic-clock pair brackets a whole batch (so the clock-read overhead is
// amortized across the batch, not charged per render — it would otherwise
// dominate sub-µs messages), and we keep the BEST batch's per-render time. Min
// strips scheduler/cache noise, leaving the compute floor — the stable,
// comparable number for ranking the slow ones.
const BATCHES = 5;
const BATCH_RENDERS = 50;

const Record = struct {
    id: []const u8,
    bytes: usize, // body length in bytes
    ns: u64, // best render time over REPEATS
};

/// collectMd recursively gathers every chat-transcript `*.md` path under
/// dir_path. A transcript is a `.md` file directly inside a `sessions/`
/// directory (`<conv>/sessions/<sid>.md` for DMs, `channels/<name>/sessions/
/// <sid>.md` for channels). The sibling `users/<uid>/{images,code,links}.md`
/// feeds and `users/<uid>/docs/*.md` are NOT MSG_-block transcripts and would
/// mis-parse as one blank-id blob, so the `sessions/` parent gate excludes them.
/// Paths are joined into (and owned by) alloc.
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

fn slowestFirst(_: void, a: Record, b: Record) bool {
    return a.ns > b.ns;
}

/// resolveChatDir returns the first candidate root that exists as a directory,
/// or null when none do (so the caller can crash loud rather than bench nothing).
fn resolveChatDir(io: Io) ?[]const u8 {
    for (CHAT_DIR_CANDIDATES) |cand| {
        var dir = Io.Dir.cwd().openDir(io, cand, .{ .iterate = true }) catch continue;
        dir.close(io);
        return cand;
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The render arena mirrors the per-message lifetime: reset before each render.
    var render_arena = std.heap.ArenaAllocator.init(alloc);
    defer render_arena.deinit();

    const chat_dir = resolveChatDir(io) orelse {
        std.debug.print("no corpus root found — tried:\n", .{});
        for (CHAT_DIR_CANDIDATES) |c| std.debug.print("  {s}\n", .{c});
        std.process.exit(1);
    };
    std.debug.print("corpus root: {s}\n", .{chat_dir});

    var files: std.ArrayList([]const u8) = .empty;
    try collectMd(io, alloc, chat_dir, &files);
    if (files.items.len == 0) {
        std.debug.print("no transcripts under {s} — expand a backup there first\n", .{chat_dir});
        std.process.exit(1);
    }

    var records: std.ArrayList(Record) = .empty;

    for (files.items) |path| {
        const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch continue;
        defer alloc.free(data);

        var file_arena = std.heap.ArenaAllocator.init(alloc);
        defer file_arena.deinit();
        const msgs = try chat_store.decodeChatFile(file_arena.allocator(), data);

        for (msgs) |m| {
            var best_per: u64 = std.math.maxInt(u64);
            var b: usize = 0;
            while (b < BATCHES) : (b += 1) {
                const t0 = Io.Clock.now(.awake, io);
                var k: usize = 0;
                while (k < BATCH_RENDERS) : (k += 1) {
                    _ = render_arena.reset(.retain_capacity);
                    _ = try markdown.render(render_arena.allocator(), m.markdown);
                }
                const t1 = Io.Clock.now(.awake, io);
                const total: u64 = @intCast(t0.durationTo(t1).nanoseconds);
                const per = total / BATCH_RENDERS;
                if (per < best_per) best_per = per;
            }
            try records.append(alloc, .{
                .id = try alloc.dupe(u8, m.id),
                .bytes = m.markdown.len,
                .ns = best_per,
            });
        }
    }

    // ── aggregates ───────────────────────────────────────────────────────────
    var total_bytes: u64 = 0;
    var total_ns: u64 = 0;
    for (records.items) |rec| {
        total_bytes += rec.bytes;
        total_ns += rec.ns;
    }
    const n = records.items.len;
    const avg_bytes = @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(n));
    const avg_us = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(n)) / 1000.0;
    const throughput = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(total_ns)) / 1e9) / 1e6;

    std.debug.print("== markdown render bench ({d} transcripts, {d} messages, best of {d}×{d} renders)\n", .{ files.items.len, n, BATCHES, BATCH_RENDERS });
    std.debug.print("   avg message length : {d:.1} bytes\n", .{avg_bytes});
    std.debug.print("   avg render time    : {d:.2} µs/msg\n", .{avg_us});
    std.debug.print("   render throughput  : {d:.1} MB/s\n", .{throughput});

    std.mem.sort(Record, records.items, {}, slowestFirst);
    std.debug.print("\n== slowest messages\n", .{});
    const top = @min(@as(usize, 5), records.items.len);
    for (records.items[0..top]) |rec| {
        const us = @as(f64, @floatFromInt(rec.ns)) / 1000.0;
        const us_per_kb = us / (@as(f64, @floatFromInt(rec.bytes)) / 1024.0);
        std.debug.print("   {d:7.2} µs  {d:6} bytes  {d:6.2} µs/KB  {s}\n", .{ us, rec.bytes, us_per_kb, rec.id });
    }
}
