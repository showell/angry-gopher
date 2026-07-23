//! wasm — the board bridge compiled for the browser (the puzzle Hint
//! button). Built by ops/build_lynrummy_wasm into solver.wasm, served
//! by zig-server/src/puzzles.zig, driven by engine_glue.js.
//!
//! ABI (same style as the chess toys — one static buffer, no
//! allocator, no imports): the caller writes an arrangement line into
//! the io buffer and calls puzzleHint(len); the plan text is written
//! back into the same buffer. Non-negative return = plan length in
//! bytes (0 = the board is already clean); negative = no plan:
//!   -1  the input didn't parse (bad stack / bad card / bad multiset)
//!   -2  FUTILE — a proof that no clean cover exists
//!   -3  the solver gave up (give-up line): no verdict
//!   -4  internal distiller failure (a bug; fail loud, never invent)

const std = @import("std");
const card = @import("card.zig");
const solver = @import("solver.zig");
const arrangement = @import("arrangement.zig");
const moves = @import("moves.zig");
const hint = @import("hint.zig");

var io_buf: [65536]u8 = undefined;

export fn ioPtr() [*]u8 {
    return &io_buf;
}

export fn ioCap() u32 {
    return io_buf.len;
}

export fn puzzleHint(len: u32) i32 {
    if (len > io_buf.len) return -1;
    const arr = arrangement.parse(io_buf[0..len]) catch return -1;
    const out = solver.solveArrangement(&arr) catch return -1;
    switch (out) {
        .solved => |sol| {
            var plan: moves.Plan = undefined;
            moves.distill(&arr, &sol.next, arr.n_stacks, &plan) catch return -4;
            return @intCast(moves.formatPlan(&plan, &io_buf).len);
        },
        .futile => return -2,
        .unknown => return -3,
    }
}

/// gameHint: the io buffer holds the BOARD arrangement line, a
/// newline, the HAND as space-separated card tokens (possibly empty),
/// and optionally a third line naming the PREVIOUS hint's objective
/// card — the stickiness that keeps hints walking one line instead of
/// flapping (session 8's lesson). Returns like puzzleHint, with 0
/// meaning "nothing to play and the board is already clean — draw";
/// -2 meaning the BOARD multiset has no cover (undo territory). A
/// `play` plan leads with its `place` line.
export fn gameHint(len: u32) i32 {
    if (len > io_buf.len) return -1;
    const input = io_buf[0..len];
    var it = std.mem.splitScalar(u8, input, '\n');
    const arr = arrangement.parse(it.next().?) catch return -1;
    var hb: [card.MAX_CARDS]card.Card = undefined;
    const hand = card.parseBoard(it.next() orelse "", &hb) catch return -1;
    const pref_line = std.mem.trim(u8, it.next() orelse "", " ");
    const pref: ?card.Card = if (pref_line.len == 0)
        null
    else
        card.parseCard(pref_line) catch return -1;
    const res = hint.gameHint(&arr, hand, pref) catch |e| return switch (e) {
        error.DistillFailed => -4,
        else => -1,
    };
    return switch (res.kind) {
        .play, .clean_board => @intCast(moves.formatPlan(&res.plan, &io_buf).len),
        .no_play => 0,
        .futile_board => -2,
        .unknown => -3,
    };
}
