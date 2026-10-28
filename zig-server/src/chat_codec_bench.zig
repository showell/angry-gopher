//! chat_codec_bench: what decoding a transcript costs, the Zig decoder
//! and its Roc twin side by side (roc-webbox docs/ROC-CHAT.md C1, R6). A
//! measuring stick, not a gate.
//!
//!   cd zig-server && zig build codec-bench [-- <transcript>]
//!
//! With no file, a synthetic transcript the size of the probe's (R6: 5 MB,
//! 11,392 blocks), written by chatStoredForm: messages of a few dozen
//! words, some with a code fence, some with a line that would read as the
//! separator. With a file, that one: the largest production transcript is
//! the box's to bring, and metal is the box's to run it on.
//!
//! For each side: the best CPU time of `rounds`, and the most memory held
//! at once (`Peak`): the Zig decoder's arena, and the Roc call's arena,
//! which also holds the call's copy of its input and the result list it
//! builds (twin.roc's function 15 returns every field of every message).

const std = @import("std");
const fixtures = @import("chat_fixtures_test.zig");
const twin = @import("roc_chat_twin");
const chat_codec = @import("chat_codec.zig");
const chat_count = @import("chat_count.zig");
const ChatMessage = @import("chat_store.zig").ChatMessage;
const Peak = @import("peak_alloc.zig").Peak;

const messages = 11_392;
const rounds = 5;

/// CPU time this process has used, user and system, in ms.
fn cpuMs() f64 {
    const r = std.posix.getrusage(std.posix.rusage.SELF);
    const us = (r.utime.sec + r.stime.sec) * std.time.us_per_s + r.utime.usec + r.stime.usec;
    return @as(f64, @floatFromInt(us)) / 1000;
}

fn mb(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) / (1 << 20);
}

const words = [_][]const u8{
    "the",
    "a",
    "chat",
    "message",
    "Steve",
    "Roc",
    "zig",
    "metal",
    "box",
    "deploy",
    "test",
    "green",
    "red",
    "transcript",
    "sidecar",
    "count",
    "frame",
    "uid",
    "topic",
    "channel",
    "\"quoted\"",
    "back\\slash",
    "caf\xc3\xa9",
    "why?",
    "yes.",
    "ok,",
};

fn synthetic(a: std.mem.Allocator) ![]u8 {
    var rng = std.Random.DefaultPrng.init(0xbe7c4);
    const r = rng.random();
    var file: std.ArrayList(u8) = .empty;
    for (0..messages) |i| {
        var md: std.ArrayList(u8) = .empty;
        for (0..r.intRangeAtMost(
            usize,
            20,
            120,
        )) |k| {
            if (k > 0) try md.append(a, if (r.uintLessThan(u8, 12) == 0) '\n' else ' ');
            try md.appendSlice(a, words[r.uintLessThan(usize, words.len)]);
        }
        if (r.uintLessThan(u8, 10) == 0) try md.appendSlice(a, "\n```zig\nconst x = 1;\n```");
        if (r.uintLessThan(u8, 50) == 0) try md.appendSlice(a, "\n-------------\nafter");
        const m: ChatMessage = .{
            .id = try std.fmt.allocPrint(
                a,
                "general_{d}",
                .{i + 1},
            ),
            .from = if (i % 3 == 0) "Steve" else "Claude",
            .at = "2026-10-25T12:00:00Z",
            .uid = if (i % 3 == 0) "1" else "2",
            .markdown = md.items,
        };
        try file.appendSlice(a, try fixtures.chatStoredForm(
            a,
            i,
            m,
        ));
    }
    return file.items;
}

pub fn main(init: std.process.Init) !void {
    const page = std.heap.page_allocator;
    var setup = std.heap.ArenaAllocator.init(page);
    defer setup.deinit();
    const sa = setup.allocator();
    const args = try init.minimal.args.toSlice(sa);
    const data = if (args.len > 1)
        try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            args[1],
            sa,
            .unlimited,
        )
    else
        try synthetic(sa);
    std.debug.print(
        "transcript: {d:.2} MB, {d} blocks\n",
        .{ mb(data.len), chat_count.countBlocks(data) },
    );

    // Zig: decodeChatFile into an arena of its own, each round fresh.
    var zig_ms: f64 = std.math.inf(f64);
    var zig_peak: usize = 0;
    var zig_n: usize = 0;
    for (0..rounds) |_| {
        var peak: Peak = .{ .child = page };
        var arena = std.heap.ArenaAllocator.init(peak.allocator());
        const t0 = cpuMs();
        zig_n = (try chat_codec.decodeChatFile(arena.allocator(), data)).len;
        zig_ms = @min(zig_ms, cpuMs() - t0);
        arena.deinit();
        zig_peak = peak.most;
    }

    // Roc: the twin's decode, the call's arena on a Peak, each round fresh;
    // the copy out of the arena (`twin.call`'s) is timed too, into `out`.
    var roc_ms: f64 = std.math.inf(f64);
    var roc_peak: usize = 0;
    var roc_n: usize = 0;
    for (0..rounds) |_| {
        var peak: Peak = .{ .child = page };
        twin.use(peak.allocator());
        var out = std.heap.ArenaAllocator.init(page);
        const t0 = cpuMs();
        const got = try twin.call(
            out.allocator(),
            15,
            &.{data},
        );
        roc_ms = @min(roc_ms, cpuMs() - t0);
        roc_n = (got.len - 1) / 5;
        out.deinit();
        twin.deinit();
        roc_peak = peak.most;
    }

    // The split alone: countBlocks, both sides.
    var zc_ms: f64 = std.math.inf(f64);
    var rc_ms: f64 = std.math.inf(f64);
    for (0..rounds) |_| {
        const t0 = cpuMs();
        std.mem.doNotOptimizeAway(chat_count.countBlocks(data));
        zc_ms = @min(zc_ms, cpuMs() - t0);
        twin.use(page);
        var out = std.heap.ArenaAllocator.init(page);
        const t1 = cpuMs();
        _ = try twin.call(
            out.allocator(),
            17,
            &.{data},
        );
        rc_ms = @min(rc_ms, cpuMs() - t1);
        out.deinit();
        twin.deinit();
    }
    std.debug.print("count blocks: zig {d:.1} ms, roc {d:.1} ms\n", .{ zc_ms, rc_ms });
    std.debug.print("zig decode: {d:.1} ms, {d} messages, peak {d:.2} MB\n", .{
        zig_ms,
        zig_n,
        mb(zig_peak),
    });
    std.debug.print("roc decode: {d:.1} ms, {d} messages, peak arena {d:.2} MB ({d:.1}x the time, {d:.1}x the memory)\n", .{
        roc_ms,
        roc_n,
        mb(roc_peak),
        roc_ms / zig_ms,
        mb(roc_peak) / mb(zig_peak),
    });
    if (zig_n != roc_n) return error.TwinsDisagree;
}
