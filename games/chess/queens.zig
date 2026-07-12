//! queens — the Eight Queens machine: place 8 queens so none attacks another.
//! Built on the same tape substrate as the Knight's Tour (core/tape.zig): the
//! search appends place/remove events, the display scrubs them, and the two
//! overlays keep their meanings — red = a queen was placed here, found doomed,
//! and retracted; indigo = no queen can live here right now (attacked).
//!
//! The click PINS the first queen: it is move 0, it is never retracted, and
//! the machine fills the OTHER seven rows top-to-bottom around it (one queen
//! per row by construction, so the search branches only on columns). The
//! classic n-queens DFS: try the next non-attacked column in this row, else
//! pull the previous row's queen and resume from its next column.

const std = @import("std");
const tape = @import("core/tape.zig").Substrate(@This());
comptime {
    @import("core/tape.zig").exportAbi(tape);
}

/// 8 queens on the board = a solution.
pub const target_count: u32 = 8;

// ---------- the machine (generates events at the tape's end) ----------

var pin_sq: u8 = 0;
var rows: [7]u8 = undefined; // the rows the machine fills, in order (pin's row skipped)
var stack_col: [7]u8 = undefined; // chosen column per filled row
var stack_idx: [7]u8 = undefined; // next column to try at that row
var stack_len: u32 = 0;
// attack masks, pinned queen included. One queen per row by construction, so
// only columns and the two diagonal families can conflict.
var cols_used: u8 = 0;
var diag_sum: u15 = 0; // r+c, 0..14
var diag_diff: u15 = 0; // r-c+7, 0..14

fn setAttack(r: u8, c: u8, on: bool) void {
    const cb = @as(u8, 1) << @intCast(c);
    const sb = @as(u15, 1) << @intCast(r + c);
    const db = @as(u15, 1) << @intCast(r + 7 - c);
    if (on) {
        cols_used |= cb;
        diag_sum |= sb;
        diag_diff |= db;
    } else {
        cols_used &= ~cb;
        diag_sum &= ~sb;
        diag_diff &= ~db;
    }
}

fn attacked(r: u8, c: u8) bool {
    return (cols_used & (@as(u8, 1) << @intCast(c))) != 0 or
        (diag_sum & (@as(u15, 1) << @intCast(r + c))) != 0 or
        (diag_diff & (@as(u15, 1) << @intCast(r + 7 - c))) != 0;
}

/// genOne runs the DFS one transition, appending exactly one event — place a
/// queen in the next open column of the current row, or (no column fits) pull
/// the previous row's queen. The substrate calls it only while the search is
/// live; solved is set by the substrate when the 8th queen lands.
pub fn genOne() void {
    const r = rows[stack_len];
    var c = stack_idx[stack_len];
    while (c < 8) : (c += 1) {
        if (!attacked(r, c)) {
            stack_idx[stack_len] = c + 1;
            stack_col[stack_len] = c;
            setAttack(r, c, true);
            stack_len += 1;
            if (stack_len < rows.len) stack_idx[stack_len] = 0;
            tape.appendPlace(r * 8 + c);
            return;
        }
    }
    // no column works in this row: backtrack to the previous machine row
    if (stack_len == 0) {
        tape.exhausted = true; // no solution with this pin
        return;
    }
    stack_len -= 1;
    const pr = rows[stack_len];
    const pc = stack_col[stack_len];
    setAttack(pr, pc, false);
    tape.appendRemove(pr * 8 + pc);
}

pub fn resetMachine() void {
    stack_len = 0;
    cols_used = 0;
    diag_sum = 0;
    diag_diff = 0;
}

// ---------- exports (the queens-specific ABI) ----------

/// init pins the first queen at `sq` and starts the search; the pinned queen
/// shows immediately and is never retracted.
pub export fn init(sq: u32) void {
    tape.reset();
    tape.started = true;
    pin_sq = @intCast(sq & 63);
    const pr: u8 = pin_sq / 8;
    setAttack(pr, pin_sq % 8, true);
    var n: usize = 0;
    for (0..8) |r| {
        if (r != pr) {
            rows[n] = @intCast(r);
            n += 1;
        }
    }
    stack_idx[0] = 0;
    tape.appendPlace(pin_sq);
    _ = tape.stepForward();
}

// impossible[sq] = 1 when the square is empty and ATTACKED — it shares a row,
// column, or diagonal with a queen on the display board, so no queen can live
// there right now. (The n-queens constraint ignores blocking, so whole lines
// are marked.) Same meaning as the knight's mask: provably unplaceable now.
var impossible: [64]u8 = [_]u8{0} ** 64;

/// computeImpossible recomputes the attacked mask from the DISPLAY board — a
/// pure function of the shown position, exact under scrubbing. Called by the
/// substrate's computeOverlays.
pub fn computeImpossible() void {
    impossible = [_]u8{0} ** 64;
    for (tape.board, 0..) |n, q| {
        if (n < 0) continue;
        const qr: i32 = @intCast(q / 8);
        const qc: i32 = @intCast(q % 8);
        for (0..64) |sq| {
            if (tape.board[sq] >= 0) continue;
            const r: i32 = @intCast(sq / 8);
            const c: i32 = @intCast(sq % 8);
            if (r == qr or c == qc or r + c == qr + qc or r - c == qr - qc) impossible[sq] = 1;
        }
    }
}

pub export fn impossiblePtr() usize {
    return @intFromPtr(&impossible);
}

// ---------- the hover graph: every square a queen there would attack ----------

const Adj = struct {
    at: [64][27]u8, // 27 = the center-square maximum (7 row + 7 col + 13 diagonal)
    count: [64]u8,
};

fn buildAdj() Adj {
    @setEvalBranchQuota(500_000);
    var a: Adj = .{ .at = undefined, .count = [_]u8{0} ** 64 };
    for (0..64) |sq| {
        const r: i32 = @intCast(sq / 8);
        const c: i32 = @intCast(sq % 8);
        for (0..64) |other| {
            if (other == sq) continue;
            const or_: i32 = @intCast(other / 8);
            const oc: i32 = @intCast(other % 8);
            if (or_ == r or oc == c or or_ + oc == r + c or or_ - oc == r - c) {
                a.at[sq][a.count[sq]] = @intCast(other);
                a.count[sq] += 1;
            }
        }
    }
    return a;
}

const adj = buildAdj();

pub export fn adjPtr() usize {
    return @intFromPtr(&adj.at);
}
pub export fn adjCountsPtr() usize {
    return @intFromPtr(&adj.count);
}
pub export fn adjStride() u32 {
    return 27;
}

// ---------- tests (native: ops/check_chess) ----------

test "attack graph shape: corner 21, center 27, symmetric" {
    try std.testing.expectEqual(@as(u8, 21), adj.count[0]); // a1
    try std.testing.expectEqual(@as(u8, 27), adj.count[27]); // d4
    var total: u32 = 0;
    for (0..64) |sq| {
        total += adj.count[sq];
        for (adj.at[sq][0..adj.count[sq]]) |other| {
            var back = false;
            for (adj.at[other][0..adj.count[other]]) |x| {
                if (x == sq) back = true;
            }
            try std.testing.expect(back);
        }
    }
    // 64 squares x (7 row + 7 col) + diagonal pairs x2; the frozen total
    try std.testing.expectEqual(@as(u32, 1456), total);
}

test "every pin square either solves or exhausts honestly; solutions are legal" {
    var solved_pins: u32 = 0;
    for (0..64) |sq| {
        init(@intCast(sq));
        while (tape.stepForward() == 1) {}
        if (tape.isSolved() == 1) {
            solved_pins += 1;
            try std.testing.expectEqual(@as(u32, 8), tape.piecesOnBoard());
            // legality: no two queens share a row, column, or diagonal
            var qs: [8]u8 = undefined;
            var n: usize = 0;
            for (tape.board, 0..) |v, s| {
                if (v >= 0) {
                    qs[n] = @intCast(s);
                    n += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 8), n);
            for (0..8) |i| {
                for (i + 1..8) |j| {
                    const ar: i32 = qs[i] / 8;
                    const ac: i32 = qs[i] % 8;
                    const br: i32 = qs[j] / 8;
                    const bc: i32 = qs[j] % 8;
                    try std.testing.expect(ar != br and ac != bc);
                    try std.testing.expect(ar + ac != br + bc and ar - ac != br - bc);
                }
            }
            // the pin survived as move 0
            try std.testing.expectEqual(@as(i8, 0), tape.board[sq]);
        } else {
            // honest exhaustion: the machine unwound completely, only the
            // pinned queen remains at the tape's end
            try std.testing.expectEqual(@as(u32, 1), tape.isExhausted());
        }
    }
    // EVERY square of the 8x8 board is part of some 8-queens solution — the
    // classic fact, rediscovered here: no pin exhausts.
    try std.testing.expectEqual(@as(u32, 64), solved_pins);
    tape.reset();
}

test "pinned event counts freeze the search order" {
    // Frozen empirically like the knight's: if these move, row/column order
    // changed and the toy animates differently. d4 nearly glides; the g8
    // corner region is the marathon (306 events, the 64-pin maximum).
    const pins = [_]struct { sq: u32, events: u32 }{
        .{ .sq = 0, .events = 218 }, // a1
        .{ .sq = 27, .events = 20 }, // d4
        .{ .sq = 62, .events = 306 }, // g8, the worst pin
    };
    for (pins) |p| {
        init(p.sq);
        while (tape.stepForward() == 1) {}
        try std.testing.expectEqual(@as(u32, 1), tape.isSolved());
        try std.testing.expectEqual(p.events, tape.tape_len);
    }
    tape.reset();
}

test "overlays: attacked mask matches the constraint at every step" {
    init(0); // a1's search backtracks plenty
    var saw_dead_end = false;
    while (true) {
        tape.computeOverlays();
        for (0..64) |sq| {
            // recompute attacked independently
            var att = false;
            for (tape.board, 0..) |v, q| {
                if (v < 0 or q == sq) continue;
                const qr: i32 = @intCast(q / 8);
                const qc: i32 = @intCast(q % 8);
                const r: i32 = @intCast(sq / 8);
                const c: i32 = @intCast(sq % 8);
                if (r == qr or c == qc or r + c == qr + qc or r - c == qr - qc) att = true;
            }
            const expect_imp: u8 = @intFromBool(tape.board[sq] < 0 and att);
            try std.testing.expectEqual(expect_imp, impossible[sq]);
            const expect_de: u8 = @intFromBool(tape.board[sq] < 0 and tape.tried[sq] > 0);
            try std.testing.expectEqual(expect_de, tape.dead_end[sq]);
            if (tape.dead_end[sq] == 1) saw_dead_end = true;
        }
        if (tape.stepForward() == 0) break;
    }
    try std.testing.expect(saw_dead_end);
    tape.reset();
}

test "scrubbing restores the exact board and the pin" {
    init(0);
    for (0..40) |_| _ = tape.stepForward();
    const snap_board = tape.board;
    const snap_on = tape.on_board;
    for (0..30) |_| _ = tape.stepForward();
    for (0..30) |_| _ = tape.stepBack();
    try std.testing.expectEqual(snap_on, tape.on_board);
    try std.testing.expectEqualSlices(i8, &snap_board, &tape.board);
    // full rewind: even the pin unwinds from the DISPLAY (event 0), board empty
    while (tape.stepBack() == 1) {}
    try std.testing.expectEqual(@as(u32, 0), tape.piecesOnBoard());
    tape.reset();
}
