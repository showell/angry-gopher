//! search_bench: what search's index costs to build, on the host (metal-vmm
//! QUEUE 155(e)). A measuring stick, not a gate.
//!
//!   cd zig-server && zig run -OReleaseFast src/search_bench.zig
//!
//! A synthetic corpus of about `corpus_bytes` (Steve: four people, ~10 MB of
//! chat), written as the store lays transcripts out, under .zig-cache/tmp:
//! the six DMs of four people and two channels, a few dozen topics each,
//! messages of a few dozen words drawn from a vocabulary of `vocabulary`
//! words, the common ones far commoner (Zipf). Then `search_index.buildAll`
//! from the disk, timed, with what it holds after (mem_meter's live bytes),
//! and a few queries. The disk cost on gopher-metal is the box's to measure.

const std = @import("std");
const Io = std.Io;
const chat_store = @import("chat_store.zig");
const search_index = @import("search_index.zig");
const mem_meter = @import("mem_meter.zig");
const store = @import("store.zig");

const corpus_bytes = 10 << 20;
const vocabulary = 20_000;
const topics_per_conv = 30;

fn ms(t0: Io.Timestamp, t1: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / std.time.ns_per_ms;
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const page = std.heap.page_allocator;
    _ = mem_meter.init(page);
    var threaded = std.Io.Threaded.init(page, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(page);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/search-bench";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    chat_store.chat_root = root;

    // The words: "w<n>", with a few real ones for the queries.
    var words = try a.alloc([]const u8, vocabulary);
    for (words, 0..) |*w, i| w.* = try std.fmt.allocPrint(a, "w{d}", .{i});
    words[0] = "the";
    words[1] = "and";
    words[500] = "layout";
    words[vocabulary - 1] = "zeppelin";
    // Zipf: the n-th word about 1/n as common, drawn through a cumulative table.
    const cumulative = try a.alloc(f64, vocabulary);
    var sum: f64 = 0;
    for (cumulative, 0..) |*c, i| {
        sum += 1.0 / @as(f64, @floatFromInt(i + 1));
        c.* = sum;
    }
    var prng = std.Random.DefaultPrng.init(155);
    const rand = prng.random();

    const convs = [_][]const u8{ "1_2", "1_3", "1_4", "2_3", "2_4", "3_4", "channels/general", "channels/random" };
    const per_conv = corpus_bytes / convs.len;
    const t_write = Io.Clock.now(.awake, io);
    var written: u64 = 0;
    var messages: usize = 0;
    for (convs) |conv| {
        const per_topic = per_conv / topics_per_conv;
        for (0..topics_per_conv) |t| {
            var body: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            while (body.items.len < per_topic) {
                n += 1;
                if (n > 1) try body.appendSlice(a, chat_store.sep);
                try body.print(a, "MSG_t{d}_{d}\nfrom: Person {d}\ndate: 2026-10-10T00:00:00Z\n\n", .{ t, n, rand.uintLessThan(u8, 4) + 1 });
                for (0..rand.intRangeAtMost(usize, 3, 60)) |k| {
                    if (k > 0) try body.append(a, ' ');
                    const x = rand.float(f64) * sum;
                    const i = std.sort.lowerBound(f64, cumulative, x, struct {
                        fn f(key: f64, item: f64) std.math.Order {
                            return std.math.order(key, item);
                        }
                    }.f);
                    try body.appendSlice(a, words[@min(i, vocabulary - 1)]);
                    if (rand.uintLessThan(u8, 10) == 0) try body.append(a, ',');
                }
            }
            messages += n;
            const path = try std.fmt.allocPrint(a, "{s}/{s}/sessions/t{d}.md", .{ root, conv, t });
            try store.write(io, a, path, body.items, .{});
            written += body.items.len;
        }
    }
    const t_built0 = Io.Clock.now(.awake, io);
    std.debug.print("corpus: {d} bytes, {d} messages, {d} transcripts, written in {d:.0} ms\n", .{ written, messages, convs.len * topics_per_conv, ms(t_write, t_built0) });

    const before = mem_meter.snapshot();
    var scratch = std.heap.ArenaAllocator.init(page);
    const t0 = Io.Clock.now(.awake, io);
    const s = search_index.buildAll(io, scratch.allocator()) orelse return error.NotBuilt;
    const t1 = Io.Clock.now(.awake, io);
    scratch.deinit();
    const after = mem_meter.snapshot();
    std.debug.print("build: {d:.0} ms; {d} messages, {d} distinct words (summed over conversations), {d} unreadable\n", .{ ms(t0, t1), s.messages, s.words, s.unreadable });
    std.debug.print("held: {d:.1} MB in {d} allocations ({d:.2}x the corpus)\n", .{
        @as(f64, @floatFromInt(after.live_bytes - before.live_bytes)) / (1 << 20),
        after.live_allocs - before.live_allocs,
        @as(f64, @floatFromInt(after.live_bytes - before.live_bytes)) / @as(f64, @floatFromInt(written)),
    });

    // Queries, as a viewer who sees everything here.
    var reach: std.ArrayList(chat_store.Reach) = .empty;
    for (convs) |c| try reach.append(a, .{ .dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, c }), .base = c, .kind = .dm });
    const idx = search_index.ready(io, a).?;
    for ([_][]const u8{ "la", "th", "w1", "zep" }) |prefix| {
        var q = std.heap.ArenaAllocator.init(page);
        defer q.deinit();
        const q0 = Io.Clock.now(.awake, io);
        const got = try idx.wordsFor(q.allocator(), reach.items, prefix, 20);
        std.debug.print("words for \"{s}\": {d} in {d:.2} ms\n", .{ prefix, got.len, ms(q0, Io.Clock.now(.awake, io)) });
    }
    for ([_][]const u8{ "the", "layout", "zeppelin" }) |word| {
        var q = std.heap.ArenaAllocator.init(page);
        defer q.deinit();
        const q0 = Io.Clock.now(.awake, io);
        const f = try idx.messagesFor(q.allocator(), reach.items, word, 500);
        std.debug.print("messages for \"{s}\": {d} matched, {d} listed, in {d:.2} ms\n", .{ word, f.matched, f.hits.len, ms(q0, Io.Clock.now(.awake, io)) });
    }
    Io.Dir.cwd().deleteTree(io, root) catch {};
}
