//! knight — the Knight's Tour wasm core: a precomputed knight-move graph plus a
//! stepwise DFS machine that emits an EVENT TAPE (place knight / remove knight,
//! one event per search transition), so the browser can play, pause, and scrub
//! the backtracking in either direction. The JS host (board.js) owns the canvas
//! and input; every decision — the graph, the move order, the search — is here.
//!
//! Two independent pieces of state:
//!   - the MACHINE (stack + visited bitmask) lives at the tape's end and only
//!     ever appends events; it never rewinds.
//!   - the DISPLAY (board move-numbers + a cursor into the tape) replays events
//!     forward or inverts them backward. Events are self-inverting because a
//!     remove always pulls the deepest knight.
//!
//! Move order is degree-ascending (a frozen Warnsdorff: try the target square
//! with the fewest onward moves first), measured empirically — naive geometric
//! order fails to finish from 54 of 64 starts within 200M events, while this
//! order completes every start within 2,520,884 events (g6, the worst; b2 is a
//! backtrack-free 64). The pinned tests below freeze those numbers.

const std = @import("std");

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

// ---------- the event tape ----------

// One byte per event: bit 7 set = place, clear = remove; low 6 bits = square.
// The cap comfortably clears the worst start (g6, 2,520,884 events).
const PLACE_BIT: u8 = 0x80;
const TAPE_CAP: u32 = 1 << 22;
var tape: [TAPE_CAP]u8 = undefined;
var tape_len: u32 = 0;

// ---------- the display (what the board shows) ----------

var cur: u32 = 0; // events [0..cur) are applied to the board
var board: [64]i8 = [_]i8{-1} ** 64; // move number per square, -1 = empty
var on_board: u32 = 0; // knights currently shown (= next move number)
var tried: [64]u32 = [_]u32{0} ** 64; // events touching each square in [0..cur)

// ---------- the machine (generates events at the tape's end) ----------

var stack_sq: [64]u8 = undefined;
var stack_idx: [64]u8 = undefined; // next neighbor index to try at that depth
var stack_len: u32 = 0;
var visited: u64 = 0;
var started = false;
var solved = false;
var exhausted = false;
var best_depth: u32 = 0;

fn bit(sq: u8) u64 {
    return @as(u64, 1) << @intCast(sq);
}

fn appendPlace(sq: u8) void {
    visited |= bit(sq);
    stack_sq[stack_len] = sq;
    stack_idx[stack_len] = 0;
    stack_len += 1;
    if (stack_len > best_depth) best_depth = stack_len;
    if (stack_len == 64) solved = true;
    tape[tape_len] = PLACE_BIT | sq;
    tape_len += 1;
}

/// genOne runs the DFS machine one transition, appending exactly one event —
/// place the next reachable knight, or pull the dead-ended one off. A no-op
/// once solved, exhausted, or (unreachable on 8x8 — see the pinned max) full.
fn genOne() void {
    if (solved or exhausted or tape_len == TAPE_CAP) return;
    const top = stack_len - 1;
    const sq = stack_sq[top];
    var idx = stack_idx[top];
    while (idx < graph.count[sq]) : (idx += 1) {
        const nb = graph.nbrs[sq][idx];
        if (visited & bit(nb) == 0) {
            stack_idx[top] = idx + 1;
            appendPlace(nb);
            return;
        }
    }
    // dead end: pull this knight off the board
    visited &= ~bit(sq);
    stack_len -= 1;
    if (stack_len == 0) exhausted = true; // no tour from this start (never on 8x8)
    tape[tape_len] = sq;
    tape_len += 1;
}

// ---------- exports ----------

/// init starts a fresh tour search from `start_sq` (0..63) and applies the
/// first place event, so the clicked square shows its knight immediately.
pub export fn init(start_sq: u32) void {
    reset();
    started = true;
    appendPlace(@intCast(start_sq & 63));
    _ = stepForward();
}

/// reset returns to the no-tour state (the hover-the-graph warmup screen).
pub export fn reset() void {
    tape_len = 0;
    cur = 0;
    board = [_]i8{-1} ** 64;
    tried = [_]u32{0} ** 64;
    on_board = 0;
    stack_len = 0;
    visited = 0;
    started = false;
    solved = false;
    exhausted = false;
    best_depth = 0;
}

/// stepForward advances the display one event, asking the machine to generate
/// it first when the cursor is at the tape's end. Returns 1 if it moved.
pub export fn stepForward() u32 {
    if (!started) return 0;
    if (cur == tape_len) genOne();
    if (cur == tape_len) return 0; // solved / exhausted: nothing more to show
    const ev = tape[cur];
    cur += 1;
    const sq = ev & 63;
    tried[sq] += 1;
    if (ev & PLACE_BIT != 0) {
        board[sq] = @intCast(on_board);
        on_board += 1;
    } else {
        on_board -= 1;
        board[sq] = -1;
    }
    return 1;
}

/// stepBack rewinds the display one event (inverting it). Returns 1 if it moved.
pub export fn stepBack() u32 {
    if (cur == 0) return 0;
    cur -= 1;
    const ev = tape[cur];
    const sq = ev & 63;
    tried[sq] -= 1;
    if (ev & PLACE_BIT != 0) {
        on_board -= 1;
        board[sq] = -1;
    } else {
        board[sq] = @intCast(on_board);
        on_board += 1;
    }
    return 1;
}

/// boardPtr is the display board in linear memory: 64 bytes of i8, the move
/// number per square (0 = the start knight) or -1 for empty. (usize = u32 on
/// wasm32; these also compile natively for the test build.)
pub export fn boardPtr() usize {
    return @intFromPtr(&board);
}

// The two display overlays, recomputed per drawn frame by computeOverlays():
//
// dead_end[sq] = 1 when a knight was placed there, its continuations were
// explored and found barren, and it was pulled off — and no knight has come
// back since. Marked only at retraction (discovery), never predictively;
// removal cascades accumulate marks. Because a square's events strictly
// alternate place/remove, this is exactly "empty AND touched by any event",
// so it falls out of the per-square `tried` counter and scrubs perfectly.
//
// unreach[sq] = 1 when the square is empty and PROVABLY out of reach: the
// tour, extending forward from the current head, can never enter it — no
// path of empty squares connects the head to it. The stronger, colder fact;
// where both hold the host paints unreach.
var dead_end: [64]u8 = [_]u8{0} ** 64;
var unreach: [64]u8 = [_]u8{0} ** 64;

/// computeOverlays refreshes both masks for the DISPLAY board — pure
/// functions of the displayed position, so they are exactly as scrubbed as
/// the knights are. The host calls it once per drawn frame.
pub export fn computeOverlays() void {
    for (0..64) |sq| {
        dead_end[sq] = @intFromBool(board[sq] < 0 and tried[sq] > 0);
    }
    computeUnreach();
}

/// computeUnreach floods (BFS) from the head knight through empty squares;
/// empty squares the flood never reaches are unreachable. At a literal dead
/// end (head has no empty neighbor) every empty square is, announcing the
/// imminent backtrack.
fn computeUnreach() void {
    unreach = [_]u8{0} ** 64;
    if (on_board == 0 or on_board == 64) return;
    var head: u8 = 0;
    for (board, 0..) |n, sq| {
        if (n == @as(i8, @intCast(on_board - 1))) head = @intCast(sq);
    }
    var reached: u64 = 0; // empty squares the tour can still enter
    var queue: [64]u8 = undefined;
    var q_len: usize = 0;
    for (graph.nbrs[head][0..graph.count[head]]) |nb| {
        if (board[nb] < 0) {
            reached |= bit(nb);
            queue[q_len] = nb;
            q_len += 1;
        }
    }
    while (q_len > 0) {
        q_len -= 1;
        const sq = queue[q_len];
        for (graph.nbrs[sq][0..graph.count[sq]]) |nb| {
            if (board[nb] < 0 and reached & bit(nb) == 0) {
                reached |= bit(nb);
                queue[q_len] = nb;
                q_len += 1;
            }
        }
    }
    for (0..64) |sq| {
        if (board[sq] < 0 and reached & bit(@intCast(sq)) == 0) unreach[sq] = 1;
    }
}

pub export fn deadEndPtr() usize {
    return @intFromPtr(&dead_end);
}
pub export fn unreachPtr() usize {
    return @intFromPtr(&unreach);
}

/// nbrsPtr / nbrCountsPtr expose the precomputed graph: a flat [64][8]u8 of
/// neighbor squares and the per-square count. The host reads them once — the
/// hover highlights ARE this graph.
pub export fn nbrsPtr() usize {
    return @intFromPtr(&graph.nbrs);
}
pub export fn nbrCountsPtr() usize {
    return @intFromPtr(&graph.count);
}

pub export fn knightsOnBoard() u32 {
    return on_board;
}
pub export fn cursor() u32 {
    return cur;
}
pub export fn tapeLen() u32 {
    return tape_len;
}
/// bestDepth is the deepest partial tour the SEARCH has reached so far (not
/// the display) — the "closest it's gotten" HUD stat.
pub export fn bestDepth() u32 {
    return best_depth;
}
pub export fn isStarted() u32 {
    return @intFromBool(started);
}
pub export fn isSolved() u32 {
    return @intFromBool(solved);
}
pub export fn isExhausted() u32 {
    return @intFromBool(exhausted);
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
        while (stepForward() == 1) {}
        try std.testing.expectEqual(@as(u32, 1), isSolved());
        try std.testing.expectEqual(@as(u32, 64), knightsOnBoard());
        try std.testing.expect(tape_len < TAPE_CAP);
        // a solved board is a permutation: every move number 0..63 exactly once
        var seen: u64 = 0;
        for (board) |n| {
            try std.testing.expect(n >= 0);
            seen |= @as(u64, 1) << @intCast(n);
        }
        try std.testing.expectEqual(~@as(u64, 0), seen);
    }
    reset();
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
        while (stepForward() == 1) {}
        try std.testing.expectEqual(p.events, tape_len);
    }
    reset();
}

test "overlays: both stay empty on a backtrack-free tour, sound when backtracking" {
    // b2 glides to a tour with zero removals: no square is ever retracted
    // (no dead_end), and since placements only shrink the empty subgraph, a
    // square that went unreachable could never be filled — contradiction with
    // completion, so unreach must stay empty too.
    init(9);
    while (true) {
        computeOverlays();
        for (unreach) |d| try std.testing.expectEqual(@as(u8, 0), d);
        for (dead_end) |d| try std.testing.expectEqual(@as(u8, 0), d);
        if (stepForward() == 0) break;
    }
    // e4 backtracks (3876 events). At every step: an unreach square is empty;
    // its empty neighbors are unreach too (a reachable neighbor would reach
    // it); no empty neighbor of the head is unreach (it's placeable right
    // now); and dead_end is exactly "empty and ever touched".
    init(28);
    var saw_unreach = false;
    var saw_dead_end = false;
    while (true) {
        computeOverlays();
        var head: usize = 0;
        for (board, 0..) |n, sq| {
            if (n == @as(i8, @intCast(on_board - 1))) head = sq;
        }
        for (0..64) |sq| {
            const expect_de: u8 = @intFromBool(board[sq] < 0 and tried[sq] > 0);
            try std.testing.expectEqual(expect_de, dead_end[sq]);
            if (dead_end[sq] == 1) saw_dead_end = true;
            if (unreach[sq] == 0) continue;
            saw_unreach = true;
            try std.testing.expect(board[sq] < 0);
            for (graph.nbrs[sq][0..graph.count[sq]]) |nb| {
                if (board[nb] < 0) try std.testing.expectEqual(@as(u8, 1), unreach[nb]);
            }
        }
        for (graph.nbrs[head][0..graph.count[head]]) |nb| {
            if (board[nb] < 0) try std.testing.expectEqual(@as(u8, 0), unreach[nb]);
        }
        if (stepForward() == 0) break;
    }
    try std.testing.expect(saw_unreach);
    try std.testing.expect(saw_dead_end);
    // solved end state: board full, so both overlays are clear
    computeOverlays();
    for (unreach) |d| try std.testing.expectEqual(@as(u8, 0), d);
    for (dead_end) |d| try std.testing.expectEqual(@as(u8, 0), d);
    reset();
}

test "dead_end marks appear at retraction, clear on re-entry, scrub cleanly" {
    // e4: run to just past the FIRST removal — that square must be marked,
    // and one step back (knight restored) must unmark it.
    init(28);
    var removed_sq: usize = 65;
    while (removed_sq == 65) {
        const before = knightsOnBoard();
        try std.testing.expectEqual(@as(u32, 1), stepForward());
        if (knightsOnBoard() < before) {
            for (0..64) |sq| {
                if (tried[sq] > 0 and board[sq] < 0) removed_sq = sq;
            }
        }
    }
    computeOverlays();
    try std.testing.expectEqual(@as(u8, 1), dead_end[removed_sq]);
    _ = stepBack();
    computeOverlays();
    try std.testing.expectEqual(@as(u8, 0), dead_end[removed_sq]);
    try std.testing.expect(board[removed_sq] >= 0);
    // scrub all the way home: every counter zero, no marks anywhere
    while (stepBack() == 1) {}
    computeOverlays();
    for (tried) |t| try std.testing.expectEqual(@as(u32, 0), t);
    for (dead_end) |d| try std.testing.expectEqual(@as(u8, 0), d);
    reset();
}

test "scrubbing back and forth restores the exact board" {
    init(28); // e4
    for (0..1000) |_| _ = stepForward();
    const snap_board = board;
    const snap_on = on_board;
    for (0..500) |_| _ = stepForward();
    for (0..500) |_| try std.testing.expectEqual(@as(u32, 1), stepBack());
    try std.testing.expectEqual(snap_on, on_board);
    try std.testing.expectEqualSlices(i8, &snap_board, &board);
    // and replaying forward from a rewound cursor agrees with the tape
    // (init itself applied event 0, hence 1 + 1000 + 500)
    for (0..500) |_| _ = stepForward();
    try std.testing.expectEqual(@as(u32, 1501), cursor());
    reset();
}
