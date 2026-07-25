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
const sim = @import("sim.zig");

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

/// agentStep: Player Two's turn engine (2026-07-25). The io buffer
/// holds the BOARD arrangement line, a newline, and the HAND as
/// space-separated card tokens. The zig side PICKS the play — the
/// sim's policy (smallest hand subset that plays, most kept player
/// edges within the size), strictly stronger than the beginner-first
/// hint — and answers with the distilled build recipe
/// (moves.formatPlan lines). The TS side lowers that recipe to
/// geometry primitives; choreography (locs, paths, crowding) never
/// enters the wasm. Returns the recipe length in bytes; 0 = stuck
/// (no subset plays: end of turn, Elm applies the draw rule);
/// negative like puzzleHint (-1 parse, -4 distiller bug).
export fn agentStep(len: u32) i32 {
    if (len > io_buf.len) return -1;
    const input = io_buf[0..len];
    var it = std.mem.splitScalar(u8, input, '\n');
    const arr = arrangement.parse(it.next().?) catch return -1;
    var hb: [card.MAX_CARDS]card.Card = undefined;
    const hand = card.parseBoard(it.next() orelse "", &hb) catch return -1;
    var plan: moves.Plan = undefined;
    const played = sim.agentPlan(&arr, hand, &plan) catch |e| return switch (e) {
        error.DistillFailed => -4,
        else => -1,
    };
    if (!played) return 0;
    return @intCast(moves.formatPlan(&plan, &io_buf).len);
}

/// gameHint: the io buffer holds the BOARD arrangement line, a
/// newline, the HAND as space-separated card tokens (possibly empty),
/// and optionally a third line naming the PREVIOUS hint's objective
/// card — the stickiness that keeps hints walking one line instead of
/// flapping (session 8's lesson). Returns like puzzleHint, except the
/// no-verdict states carry FUTILITY CERTIFICATES as text (Steve's
/// ask, 2026-07-24): a positive return is the text length, and the
/// text is either a plan or a sentinel-prefixed line —
///   "!noplay: <why each hand card can't play>"  (draw territory)
///   "!futile: <why the board has no cover>"     (undo territory)
/// The glue owns presentation. A `play` plan leads with its `place`
/// line.
export fn gameHint(len: u32) i32 {
    if (len > io_buf.len) return -1;
    const input = io_buf[0..len];
    var it = std.mem.splitScalar(u8, input, '\n');
    const arr = arrangement.parse(it.next().?) catch return -1;
    var hb: [card.MAX_CARDS]card.Card = undefined;
    const hand = card.parseBoard(it.next() orelse "", &hb) catch return -1;
    // Line 3: optional objective token and/or the "!played" flag,
    // space-separated.
    var just_played = false;
    var pref: ?card.Card = null;
    var pit = std.mem.tokenizeScalar(u8, it.next() orelse "", ' ');
    while (pit.next()) |tok| {
        if (std.mem.eql(u8, tok, "!played")) {
            just_played = true;
        } else {
            pref = card.parseCard(tok) catch return -1;
        }
    }
    const res = hint.gameHint(&arr, hand, pref, just_played) catch |e| return switch (e) {
        error.DistillFailed => -4,
        else => -1,
    };
    switch (res.kind) {
        .play, .clean_board => return @intCast(moves.formatPlan(&res.plan, &io_buf).len),
        // The parsed board and hand no longer need the input text, so
        // the certificates write straight back into io_buf: sentinel
        // at 0, ": " reserved, certificate text after it.
        .no_play => {
            const head = "!noplay";
            @memcpy(io_buf[0..head.len], head);
            const certs = hint.formatNoPlayCerts(&arr, hand, io_buf[head.len + 2 ..]);
            if (certs.len == 0) return head.len;
            @memcpy(io_buf[head.len .. head.len + 2], ": ");
            return @intCast(head.len + 2 + certs.len);
        },
        .futile_board => {
            const head = "!futile";
            @memcpy(io_buf[0..head.len], head);
            const why = hint.formatBoardFutile(&arr, io_buf[head.len + 2 ..]);
            if (why.len == 0) return head.len;
            @memcpy(io_buf[head.len .. head.len + 2], ": ");
            return @intCast(head.len + 2 + why.len);
        },
        .unknown => return -3,
    }
}
