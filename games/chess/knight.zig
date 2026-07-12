//! knight — the Knight's Tour machine: a precomputed knight-move graph plus a
//! stepwise DFS that tries to visit all 64 squares exactly once. Built on the
//! shared tape substrate (../core/tape.zig), which owns the scrubbable event
//! tape, the display, and the dead-end overlay; this module owns only what is
//! knight-shaped — the graph, the search, and the unreachability overlay. The
//! JS host (board.js) owns the canvas and input; every decision is zig's.
//!
//! Move order is degree-ascending (a frozen Warnsdorff: try the target square
//! with the fewest onward moves first), measured empirically — naive geometric
//! order fails to finish from 54 of 64 starts within 200M events, while this
//! order completes every start within 2,520,884 events (g6, the worst; b2 is a
//! backtrack-free 64). The pinned tests below freeze those numbers.

const std = @import("std");
const tape = @import("core/tape.zig").Substrate(@This());
comptime {
    @import("core/tape.zig").exportAbi(tape);
}

/// 64 knights on the board = a complete tour.
pub const target_count: u32 = 64;

// ---------- the precomputed graph ----------

const Graph = struct {
    nbrs: [64][8]u8,
    count: [64]u8,
};

fn buildGraph() Graph {
    @setEvalBranchQuota(200_000);
    const deltas = [8][2]i8{
        .{ 1, 2 },   .{ 2, 1 },   .{ 2, -1 }, .{ 1, -2 },
        .{ -1, -2 }, .{ -2, -1 }, .{ -2, 1 }, .{ -1, 2 },
    };
    var g: Graph = .{ .nbrs = undefined, .count = [_]u8{0} ** 64 };
    for (0..64) |sq| {
        const r: i8 = @intCast(sq / 8);
        const c: i8 = @intCast(sq % 8);
        for (deltas) |d| {
            const nr = r + d[0];
            const nc = c + d[1];
            if (nr < 0 or nr > 7 or nc < 0 or nc > 7) continue;
            g.nbrs[sq][g.count[sq]] = @intCast(nr * 8 + nc);
            g.count[sq] += 1;
        }
    }
    // Reorder each square's list degree-ascending (insertion sort; ties keep
    // the geometric order above, which the pinned counts freeze).
    for (0..64) |sq| {
        var i: usize = 1;
        while (i < g.count[sq]) : (i += 1) {
            const v = g.nbrs[sq][i];
            var j = i;
            while (j > 0 and g.count[g.nbrs[sq][j - 1]] > g.count[v]) : (j -= 1) {
                g.nbrs[sq][j] = g.nbrs[sq][j - 1];
            }
            g.nbrs[sq][j] = v;
        }
    }
    return g;
}

const graph = buildGraph();

// ---------- the machine (generates events at the tape's end) ----------

var stack_sq: [64]u8 = undefined;
var stack_idx: [64]u8 = undefined; // next neighbor index to try at that depth
var stack_len: u32 = 0;
var visited: u64 = 0;

fn bit(sq: u8) u64 {
    return @as(u64, 1) << @intCast(sq);
}

fn pushKnight(sq: u8) void {
    visited |= bit(sq);
    stack_sq[stack_len] = sq;
    stack_idx[stack_len] = 0;
    stack_len += 1;
    tape.appendPlace(sq);
}

/// genOne runs the DFS machine one transition, appending exactly one event —
/// place the next reachable knight, or pull the dead-ended one off. The
/// substrate calls it only while the search is live.
pub fn genOne() void {
    const top = stack_len - 1;
    const sq = stack_sq[top];
    var idx = stack_idx[top];
    while (idx < graph.count[sq]) : (idx += 1) {
        const nb = graph.nbrs[sq][idx];
        if (visited & bit(nb) == 0) {
            stack_idx[top] = idx + 1;
            pushKnight(nb);
            return;
        }
    }
    // dead end: pull this knight off the board
    visited &= ~bit(sq);
    stack_len -= 1;
    if (stack_len == 0) tape.exhausted = true; // no tour from this start (never on 8x8)
    tape.appendRemove(sq);
}

pub fn resetMachine() void {
    stack_len = 0;
    visited = 0;
}

// ---------- exports (the knight-specific ABI) ----------

/// init starts a fresh tour search from `start_sq` (0..63) and applies the
/// first place event, so the clicked square shows its knight immediately.
pub export fn init(start_sq: u32) void {
    tape.reset();
    tape.started = true;
    pushKnight(@intCast(start_sq & 63));
    _ = tape.stepForward();
}

// impossible[sq] = 1 when the square is empty and PROVABLY out of reach: the
// tour, extending forward from the current head, can never enter it — no
// path of empty squares connects the head to it. Stronger and colder than a
// dead-end mark; where both hold the host paints this one.
var impossible: [64]u8 = [_]u8{0} ** 64;

/// computeImpossible floods (BFS) from the head knight through empty squares;
/// empty squares the flood never reaches are unreachable. At a literal dead
/// end (head has no empty neighbor) every empty square is, announcing the
/// imminent backtrack. Called by the substrate's computeOverlays.
pub fn computeImpossible() void {
    impossible = [_]u8{0} ** 64;
    if (tape.on_board == 0 or tape.on_board == 64) return;
    var head: u8 = 0;
    for (tape.board, 0..) |n, sq| {
        if (n == @as(i8, @intCast(tape.on_board - 1))) head = @intCast(sq);
    }
    var reached: u64 = 0; // empty squares the tour can still enter
    var queue: [64]u8 = undefined;
    var q_len: usize = 0;
    for (graph.nbrs[head][0..graph.count[head]]) |nb| {
        if (tape.board[nb] < 0) {
            reached |= bit(nb);
            queue[q_len] = nb;
            q_len += 1;
        }
    }
    while (q_len > 0) {
        q_len -= 1;
        const sq = queue[q_len];
        for (graph.nbrs[sq][0..graph.count[sq]]) |nb| {
            if (tape.board[nb] < 0 and reached & bit(nb) == 0) {
                reached |= bit(nb);
                queue[q_len] = nb;
                q_len += 1;
            }
        }
    }
    for (0..64) |sq| {
        if (tape.board[sq] < 0 and reached & bit(@intCast(sq)) == 0) impossible[sq] = 1;
    }
}

pub export fn impossiblePtr() usize {
    return @intFromPtr(&impossible);
}

/// adjPtr / adjCountsPtr / adjStride expose the precomputed move graph as a
/// flat [64][stride]u8 plus a per-square count. The host reads them once —
/// the hover highlights ARE this graph.
pub export fn adjPtr() usize {
    return @intFromPtr(&graph.nbrs);
}
pub export fn adjCountsPtr() usize {
    return @intFromPtr(&graph.count);
}
pub export fn adjStride() u32 {
    return 8;
}

// ---------- tests (native: ops/check_chess) ----------

test "graph shape: degrees, symmetry, 336 edges" {
    var total: u32 = 0;
    for (0..64) |sq| {
        total += graph.count[sq];
        // every edge is symmetric
        for (graph.nbrs[sq][0..graph.count[sq]]) |nb| {
            var back = false;
            for (graph.nbrs[nb][0..graph.count[nb]]) |x| {
                if (x == sq) back = true;
            }
            try std.testing.expect(back);
        }
    }
    try std.testing.expectEqual(@as(u32, 336), total);
    try std.testing.expectEqual(@as(u8, 2), graph.count[0]); // a1 corner
    try std.testing.expectEqual(@as(u8, 8), graph.count[27]); // d4 center
}

test "every start square reaches a full tour within the tape" {
    for (0..64) |sq| {
        init(@intCast(sq));
        while (tape.stepForward() == 1) {}
        try std.testing.expectEqual(@as(u32, 1), tape.isSolved());
        try std.testing.expectEqual(@as(u32, 64), tape.piecesOnBoard());
        try std.testing.expect(tape.tape_len < tape.TAPE_CAP);
        // a solved board is a permutation: every move number 0..63 exactly once
        var seen: u64 = 0;
        for (tape.board) |n| {
            try std.testing.expect(n >= 0);
            seen |= @as(u64, 1) << @intCast(n);
        }
        try std.testing.expectEqual(~@as(u64, 0), seen);
    }
    tape.reset();
}

test "pinned event counts freeze the move ordering" {
    // b2 glides backtrack-free (64 places); g6 is the marathon. If either
    // number moves, the graph ordering changed and the toy plays differently.
    const pins = [_]struct { sq: u32, events: u32 }{
        .{ .sq = 9, .events = 64 }, // b2
        .{ .sq = 46, .events = 2_520_884 }, // g6
    };
    for (pins) |p| {
        init(p.sq);
        while (tape.stepForward() == 1) {}
        try std.testing.expectEqual(p.events, tape.tape_len);
    }
    tape.reset();
}

test "overlays: both stay empty on a backtrack-free tour, sound when backtracking" {
    // b2 glides to a tour with zero removals: no square is ever retracted
    // (no dead_end), and since placements only shrink the empty subgraph, a
    // square that went unreachable could never be filled — contradiction with
    // completion, so impossible must stay empty too.
    init(9);
    while (true) {
        tape.computeOverlays();
        for (impossible) |d| try std.testing.expectEqual(@as(u8, 0), d);
        for (tape.dead_end) |d| try std.testing.expectEqual(@as(u8, 0), d);
        if (tape.stepForward() == 0) break;
    }
    // e4 backtracks (3876 events). At every step: an impossible square is
    // empty; its empty neighbors are impossible too (a reachable neighbor
    // would reach it); no empty neighbor of the head is impossible (it's
    // placeable right now); and dead_end is exactly "empty and ever touched".
    init(28);
    var saw_impossible = false;
    var saw_dead_end = false;
    while (true) {
        tape.computeOverlays();
        var head: usize = 0;
        for (tape.board, 0..) |n, sq| {
            if (n == @as(i8, @intCast(tape.on_board - 1))) head = sq;
        }
        for (0..64) |sq| {
            const expect_de: u8 = @intFromBool(tape.board[sq] < 0 and tape.tried[sq] > 0);
            try std.testing.expectEqual(expect_de, tape.dead_end[sq]);
            if (tape.dead_end[sq] == 1) saw_dead_end = true;
            if (impossible[sq] == 0) continue;
            saw_impossible = true;
            try std.testing.expect(tape.board[sq] < 0);
            for (graph.nbrs[sq][0..graph.count[sq]]) |nb| {
                if (tape.board[nb] < 0) try std.testing.expectEqual(@as(u8, 1), impossible[nb]);
            }
        }
        for (graph.nbrs[head][0..graph.count[head]]) |nb| {
            if (tape.board[nb] < 0) try std.testing.expectEqual(@as(u8, 0), impossible[nb]);
        }
        if (tape.stepForward() == 0) break;
    }
    try std.testing.expect(saw_impossible);
    try std.testing.expect(saw_dead_end);
    // solved end state: board full, so both overlays are clear
    tape.computeOverlays();
    for (impossible) |d| try std.testing.expectEqual(@as(u8, 0), d);
    for (tape.dead_end) |d| try std.testing.expectEqual(@as(u8, 0), d);
    tape.reset();
}

test "dead_end marks appear at retraction, clear on re-entry, scrub cleanly" {
    // e4: run to just past the FIRST removal — that square must be marked,
    // and one step back (knight restored) must unmark it.
    init(28);
    var removed_sq: usize = 65;
    while (removed_sq == 65) {
        const before = tape.piecesOnBoard();
        try std.testing.expectEqual(@as(u32, 1), tape.stepForward());
        if (tape.piecesOnBoard() < before) {
            for (0..64) |sq| {
                if (tape.tried[sq] > 0 and tape.board[sq] < 0) removed_sq = sq;
            }
        }
    }
    tape.computeOverlays();
    try std.testing.expectEqual(@as(u8, 1), tape.dead_end[removed_sq]);
    _ = tape.stepBack();
    tape.computeOverlays();
    try std.testing.expectEqual(@as(u8, 0), tape.dead_end[removed_sq]);
    try std.testing.expect(tape.board[removed_sq] >= 0);
    // scrub all the way home: every counter zero, no marks anywhere
    while (tape.stepBack() == 1) {}
    tape.computeOverlays();
    for (tape.tried) |t| try std.testing.expectEqual(@as(u32, 0), t);
    for (tape.dead_end) |d| try std.testing.expectEqual(@as(u8, 0), d);
    tape.reset();
}

test "scrubbing back and forth restores the exact board" {
    init(28); // e4
    for (0..1000) |_| _ = tape.stepForward();
    const snap_board = tape.board;
    const snap_on = tape.on_board;
    for (0..500) |_| _ = tape.stepForward();
    for (0..500) |_| try std.testing.expectEqual(@as(u32, 1), tape.stepBack());
    try std.testing.expectEqual(snap_on, tape.on_board);
    try std.testing.expectEqualSlices(i8, &snap_board, &tape.board);
    // and replaying forward from a rewound cursor agrees with the tape
    // (init itself applied event 0, hence 1 + 1000 + 500)
    for (0..500) |_| _ = tape.stepForward();
    try std.testing.expectEqual(@as(u32, 1501), tape.cursor());
    tape.reset();
}
