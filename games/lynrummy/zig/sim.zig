//! sim — full-game agent self-play on the zig solver. The game rules
//! mirror ts/full_game/ (the production TS harness): both 15-card
//! hands dealt before play, alternate turns, a turn is plays-until-
//! stuck then the draw rule (hand emptied → 5, stuck without playing
//! → 3, stuck after playing → 0), game ends when the draw pile drops
//! to 10 or fewer.
//!
//! The deal is BIT-EXACT with ts/baseline_deal.ts — same opening
//! board, same 81-card remainder in the same enumeration order, same
//! mulberry32 + Fisher-Yates — so a seed names the identical game in
//! both engines and the bake-off compares players, not deals.
//!
//! The agent plays STRONG, not beginner-shaped (Steve, 2026-07-23:
//! "the agent plays stronger than the hint system reveals"): within a
//! turn it greedily plays any hand subset whose augmented board
//! covers, singles before pairs before triples, re-checking singles
//! after every success; among playable subsets of one size the most
//! kept edges wins (a near cover keeps the board warm for the next
//! solve). Self-play boards are always clean — every play lands as a
//! full cover — so there is no grooming step to take.

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");
const arrangement = @import("arrangement.zig");
const solver = @import("solver.zig");

pub const HAND_SIZE = 15;
pub const NUM_PLAYERS = 2;
pub const STOP_AT_DECK = 10;
pub const MAX_TURNS = 200;

// Probes run the one converged pipeline (solveArrangement: repair,
// then the sweep oracle) — the same solve the hints use. A probe
// give-up counts as not-playable AND lands in the stats — that is
// the late-game sensor.

// ---------- the deal (bit-exact vs ts/baseline_deal.ts) ----------

pub const OPENING_BOARD =
    "KS>AS>2S>3S TD>JD>QD>KD 2H>3H>4H 7S=7D=7C AC=AD=AH 2C>3D>4C>5H>6S>7H";

/// One step of mulberry32. Faithful to the JS original: all the
/// arithmetic is 32-bit (Math.imul = wrapping multiply, >>> =
/// unsigned shift, ^= coerces its f64 addend through ToInt32, which
/// is exactly u32 wrapping add), and the final divide is one exact
/// IEEE f64 operation — so the stream matches JS bit for bit.
fn mulberryNext(state: *u32) f64 {
    state.* +%= 0x6d2b79f5;
    var t: u32 = state.*;
    t = (t ^ (t >> 15)) *% (t | 1);
    t ^= t +% ((t ^ (t >> 7)) *% (t | 61));
    return @as(f64, @floatFromInt(t ^ (t >> 14))) / 4294967296.0;
}

/// Fisher-Yates, same index arithmetic as the TS shuffle:
/// j = floor(rand() * (i + 1)) computed in f64.
fn shuffle(cards: []card.Card, state: *u32) void {
    var i: usize = cards.len - 1;
    while (i > 0) : (i -= 1) {
        const j: usize = @intFromFloat(mulberryNext(state) * @as(f64, @floatFromInt(i + 1)));
        std.mem.swap(card.Card, &cards[i], &cards[j]);
    }
}

/// The 81 cards not on the opening board, in the TS enumeration order
/// (suit C,D,S,H — the TS suit codes — then rank A..K, then deck 0,1;
/// the 23 opening cards are all deck 0). Order matters: the shuffle
/// permutes positions, so the pre-shuffle sequence is part of the
/// deal's identity.
fn remainingCards() [81]card.Card {
    const ts_to_zig_suit = [4]u2{ 2, 1, 3, 0 }; // C,D,S,H -> zig H,D,C,S codes
    var on_board = [_]bool{false} ** graph.N;
    const arr = arrangement.parse(OPENING_BOARD) catch unreachable;
    for (arr.cards[0..arr.nCards()]) |c|
        on_board[@as(usize, c.suit) * 13 + c.rank] = true;
    var out: [81]card.Card = undefined;
    var n: usize = 0;
    for (0..4) |ts_suit| {
        const zs = ts_to_zig_suit[ts_suit];
        for (0..13) |r| {
            for (0..2) |deck| {
                if (deck == 0 and on_board[@as(usize, zs) * 13 + r]) continue;
                out[n] = .{ .rank = @intCast(r), .suit = zs, .deck = @intCast(deck) };
                n += 1;
            }
        }
    }
    std.debug.assert(n == 81);
    return out;
}

pub const Deal = struct {
    board: arrangement.Arrangement,
    hands: [NUM_PLAYERS][card.MAX_CARDS]card.Card,
    hand_len: [NUM_PLAYERS]usize,
    deck: [81]card.Card,
    deck_len: usize,
};

pub fn dealGame(seed: u32) Deal {
    var d: Deal = undefined;
    d.board = arrangement.parse(OPENING_BOARD) catch unreachable;
    var pool = remainingCards();
    var state = seed;
    shuffle(&pool, &state);
    for (0..NUM_PLAYERS) |p| {
        @memcpy(d.hands[p][0..HAND_SIZE], pool[p * HAND_SIZE .. (p + 1) * HAND_SIZE]);
        d.hand_len[p] = HAND_SIZE;
    }
    const rest = pool[NUM_PLAYERS * HAND_SIZE ..];
    @memcpy(d.deck[0..rest.len], rest);
    d.deck_len = rest.len;
    return d;
}

// ---------- the game loop ----------

pub const StopReason = enum { deck_low, max_turns, hand_and_deck_empty };

pub const TurnRecord = struct {
    player: u8,
    plays: u8, // play actions taken
    played: u8, // hand cards landed
    drew: u8,
    hand_after: u8,
    stacks_after: u8,
};

/// Solver telemetry across the game. `steps` sums solver.steps_used
/// after each call — that counter reports the LAST phase of a
/// portfolio solve, so this is difficulty telemetry, not an exact
/// work total. The unknowns are the interesting part: a probe or
/// full-budget give-up is a board the budget couldn't answer — the
/// late-game specimens Steve wants published.
pub const Stats = struct {
    probe_calls: u32 = 0,
    probe_unknowns: u32 = 0,
    first_unknown_turn: u16 = 0, // 0 = never
    steps: u64 = 0,
    max_steps: u64 = 0,
    max_steps_turn: u16 = 0,
    // Where the steps go, by probe verdict.
    steps_solved: u64 = 0,
    steps_futile: u64 = 0,
    steps_unknown: u64 = 0,
    probes_solved: u32 = 0,
};

/// The full game state at the START of the first STUCK turn — the
/// agent held cards and found no play at all (Steve's specimen
/// criterion, 2026-07-23, after give-up cuts proved trivially
/// playable): the crisp human question is "the machine says nothing
/// plays here; can you find one?"
pub const CutState = struct {
    turn: u16,
    active: u8,
    board: arrangement.Arrangement,
    hands: [NUM_PLAYERS][card.MAX_CARDS]card.Card,
    hand_len: [NUM_PLAYERS]usize,
    deck: [81]card.Card,
    deck_len: usize,
};

pub const GameResult = struct {
    seed: u32,
    n_turns: u16,
    stopped: StopReason,
    turns: [MAX_TURNS]TurnRecord,
    board: arrangement.Arrangement,
    hand_len: [NUM_PLAYERS]u8,
    played_total: [NUM_PLAYERS]u16,
    deck_left: u8,
    stats: Stats,
    cut: ?CutState,
};

pub fn playGame(seed: u32) card.Error!GameResult {
    var deal = dealGame(seed);
    var deck_pos: usize = 0;
    var res: GameResult = undefined;
    res.seed = seed;
    res.n_turns = 0;
    res.stopped = .max_turns;
    res.played_total = .{ 0, 0 };
    res.stats = .{};
    res.cut = null;
    var active: usize = 0;
    var turn: u16 = 1;
    while (deal.deck_len - deck_pos > STOP_AT_DECK) {
        if (turn > MAX_TURNS) break;
        const before = deal;
        const before_pos = deck_pos;
        const rec = try playTurn(&deal, active, &deck_pos, turn, &res.stats);
        if (res.cut == null and rec.played == 0 and before.hand_len[active] > 0)
            res.cut = cutFrom(&before, before_pos, turn, active);
        res.turns[res.n_turns] = rec;
        res.n_turns += 1;
        res.played_total[active] += rec.played;
        assertConserved(&deal, deck_pos);
        active = (active + 1) % NUM_PLAYERS;
        if (deal.hand_len[0] == 0 and deal.hand_len[1] == 0 and deck_pos == deal.deck_len) {
            res.stopped = .hand_and_deck_empty;
            break;
        }
        turn += 1;
    }
    if (res.stopped == .max_turns and deal.deck_len - deck_pos <= STOP_AT_DECK)
        res.stopped = .deck_low;
    res.board = deal.board;
    for (0..NUM_PLAYERS) |p| res.hand_len[p] = @intCast(deal.hand_len[p]);
    res.deck_left = @intCast(deal.deck_len - deck_pos);
    return res;
}

fn playTurn(deal: *Deal, active: usize, deck_pos: *usize, turn: u16, stats: *Stats) card.Error!TurnRecord {
    var played: u8 = 0;
    var plays: u8 = 0;
    outer: while (true) {
        inline for (.{ 1, 2, 3 }) |k| {
            const hand = deal.hands[active][0..deal.hand_len[active]];
            if (try findPlay(&deal.board, hand, k, turn, stats)) |pick| {
                applyPlay(deal, active, pick.idx[0..k], &pick.next);
                played += k;
                plays += 1;
                continue :outer;
            }
        }
        break;
    }
    const draw_want: usize = if (deal.hand_len[active] == 0) 5 else if (played == 0) 3 else 0;
    const drew = @min(draw_want, deal.deck_len - deck_pos.*);
    for (0..drew) |i| {
        deal.hands[active][deal.hand_len[active]] = deal.deck[deck_pos.* + i];
        deal.hand_len[active] += 1;
    }
    deck_pos.* += drew;
    return .{
        .player = @intCast(active),
        .plays = plays,
        .played = played,
        .drew = @intCast(drew),
        .hand_after = @intCast(deal.hand_len[active]),
        .stacks_after = @intCast(deal.board.n_stacks),
    };
}

const Pick = struct { idx: [3]u8, kept: i32, next: [graph.SLOTS]u8 };

/// Probe every size-k hand subset with a satisfaction solve; the
/// winner keeps the most player edges among the first covers found
/// (tie: hand order). Give-ups count as not-playable — the solver's
/// internal budgets are the honesty line, same as the hints.
fn findPlay(
    arr: *const arrangement.Arrangement,
    hand: []const card.Card,
    comptime k: usize,
    turn: u16,
    stats: *Stats,
) card.Error!?Pick {
    if (hand.len < k) return null;
    var best: ?Pick = null;
    var idx: [3]u8 = .{ 0, 1, 2 };
    while (true) {
        var a = arr.*;
        for (idx[0..k]) |hi| appendSingle(&a, hand[hi]);
        stats.probe_calls += 1;
        switch (try solver.solveArrangement(&a)) {
            .solved => |sol| {
                const kept = arrangement.reportKept(&a, &sol.next).kept_edges;
                if (best == null or kept > best.?.kept)
                    best = .{ .idx = idx, .kept = kept, .next = sol.next };
                stats.probes_solved += 1;
                stats.steps_solved += solver.steps_used;
            },
            .unknown => {
                stats.probe_unknowns += 1;
                if (stats.first_unknown_turn == 0) stats.first_unknown_turn = turn;
                stats.steps_unknown += solver.steps_used;
            },
            .futile => stats.steps_futile += solver.steps_used,
        }
        noteSteps(stats, turn);
        var j: usize = k;
        while (j > 0) : (j -= 1) {
            if (idx[j - 1] < hand.len - (k - j) - 1) {
                idx[j - 1] += 1;
                for (j..k) |m| idx[m] = idx[m - 1] + 1;
                break;
            }
        }
        if (j == 0) break;
    }
    return best;
}

/// Land the chosen subset: the probe's own cover BECOMES the board
/// (no second solve — the winner's cover is already in hand) and the
/// cards leave the hand.
fn applyPlay(deal: *Deal, active: usize, idxs: []const u8, next: *const [graph.SLOTS]u8) void {
    var a = deal.board;
    const hand = deal.hands[active][0..deal.hand_len[active]];
    for (idxs) |hi| appendSingle(&a, hand[hi]);
    deal.board = coverToArrangement(a.cards[0..a.nCards()], next);
    var i: usize = idxs.len;
    while (i > 0) {
        i -= 1;
        removeHandCard(deal, active, idxs[i]);
    }
}

fn removeHandCard(deal: *Deal, active: usize, at: u8) void {
    const len = deal.hand_len[active];
    for (at..len - 1) |i| deal.hands[active][i] = deal.hands[active][i + 1];
    deal.hand_len[active] = len - 1;
}

fn appendSingle(a: *arrangement.Arrangement, c: card.Card) void {
    const n = a.start[a.n_stacks];
    a.cards[n] = c;
    a.n_stacks += 1;
    a.start[a.n_stacks] = n + 1;
}

/// Read a cover's chains back as stacks. Slot dressing (which copy
/// wears the ') follows the cover, not the physical deal — copies are
/// dressing everywhere in the solver, and the sim conserves cards at
/// (suit, rank) multiset level to match.
fn coverToArrangement(cards: []const card.Card, next: *const [graph.SLOTS]u8) arrangement.Arrangement {
    const counts = card.buildCounts(cards) catch unreachable;
    var present = [_]bool{false} ** graph.SLOTS;
    for (0..4) |s| {
        for (0..13) |r| {
            const base: u8 = @intCast(s * 13 + r);
            if (counts[s][r] >= 1) present[base] = true;
            if (counts[s][r] == 2) present[base + 52] = true;
        }
    }
    var incoming = [_]bool{false} ** graph.SLOTS;
    for (0..graph.SLOTS) |i| {
        if (next[i] != graph.NONE) incoming[next[i]] = true;
    }
    var out: arrangement.Arrangement = undefined;
    out.n_stacks = 0;
    out.start[0] = 0;
    var n: u8 = 0;
    for (0..graph.SLOTS) |h| {
        if (!present[h] or incoming[h]) continue;
        const first = n;
        var cur: u8 = @intCast(h);
        while (true) {
            out.cards[n] = .{
                .rank = @intCast(graph.rankOf(cur)),
                .suit = @intCast(graph.suitOf(cur)),
                .deck = @intFromBool(cur >= graph.N),
            };
            n += 1;
            cur = next[cur];
            if (cur == graph.NONE) break;
        }
        // A cover is melds: nothing shorter than 3 can come back.
        std.debug.assert(n - first >= 3);
        out.n_stacks += 1;
        out.start[out.n_stacks] = n;
    }
    std.debug.assert(n == cards.len);
    return out;
}

fn cutFrom(deal: *const Deal, deck_pos: usize, turn: u16, active: usize) CutState {
    var c: CutState = undefined;
    c.turn = turn;
    c.active = @intCast(active);
    c.board = deal.board;
    for (0..NUM_PLAYERS) |p| {
        c.hand_len[p] = deal.hand_len[p];
        @memcpy(c.hands[p][0..c.hand_len[p]], deal.hands[p][0..c.hand_len[p]]);
    }
    c.deck_len = deal.deck_len - deck_pos;
    @memcpy(c.deck[0..c.deck_len], deal.deck[deck_pos..deal.deck_len]);
    dressBoardPhysical(&c);
    return c;
}

/// The sim's covers re-dress copies freely (dressing), but a
/// PUBLISHED state must agree with the physical cards: a board copy
/// of a (suit, rank) wears whatever deck flag the hands and deck do
/// not hold. Board-holds-both pairs get 0 then 1 in board order.
fn dressBoardPhysical(c: *CutState) void {
    var avail: [4][13][2]u8 = @splat(@splat(.{ 1, 1 }));
    for (0..NUM_PLAYERS) |p| {
        for (c.hands[p][0..c.hand_len[p]]) |cd| {
            std.debug.assert(avail[cd.suit][cd.rank][cd.deck] == 1);
            avail[cd.suit][cd.rank][cd.deck] = 0;
        }
    }
    for (c.deck[0..c.deck_len]) |cd| {
        std.debug.assert(avail[cd.suit][cd.rank][cd.deck] == 1);
        avail[cd.suit][cd.rank][cd.deck] = 0;
    }
    for (c.board.cards[0..c.board.nCards()]) |*cd| {
        const a = &avail[cd.suit][cd.rank];
        const flag: u1 = if (a[0] == 1) 0 else 1;
        std.debug.assert(a[flag] == 1);
        a[flag] = 0;
        cd.deck = flag;
    }
}

fn noteSteps(stats: *Stats, turn: u16) void {
    const s = solver.steps_used;
    stats.steps += s;
    if (s > stats.max_steps) {
        stats.max_steps = s;
        stats.max_steps_turn = turn;
    }
}

/// Every (suit, rank) must appear exactly twice across board + hands +
/// remaining deck, every turn. Copy dressing may migrate between the
/// board's two copies of a pair; the multiset never changes.
fn assertConserved(deal: *const Deal, deck_pos: usize) void {
    var counts: [4][13]u8 = @splat(@splat(0));
    for (deal.board.cards[0..deal.board.nCards()]) |c| counts[c.suit][c.rank] += 1;
    for (0..NUM_PLAYERS) |p| {
        for (deal.hands[p][0..deal.hand_len[p]]) |c| counts[c.suit][c.rank] += 1;
    }
    for (deal.deck[deck_pos..deal.deck_len]) |c| counts[c.suit][c.rank] += 1;
    for (0..4) |s| {
        for (0..13) |r| std.debug.assert(counts[s][r] == 2);
    }
}

// ---------- bake-off driver ----------

fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub fn main() !void {
    const p = std.debug.print;
    const seeds = [_]u32{ 42, 43, 44, 100, 200, 300 };
    for (seeds) |seed| {
        const t0 = monotonicMs();
        const res = try playGame(seed);
        const ms = monotonicMs() - t0;
        p(
            "seed={d} {d} turns, {s} [{d}ms] played={d}/{d} hands_left={d}/{d} deck={d} stacks={d}\n",
            .{
                seed,                res.n_turns,         @tagName(res.stopped), ms,
                res.played_total[0], res.played_total[1], res.hand_len[0],       res.hand_len[1],
                res.deck_left,       res.board.n_stacks,
            },
        );
        p(
            "  probes={d} (solved={d} unknown={d}, first_turn={d}) steps={d} (solved={d} futile={d} unknown={d}) max_steps={d}@turn{d}\n",
            .{
                res.stats.probe_calls,  res.stats.probes_solved, res.stats.probe_unknowns,
                res.stats.first_unknown_turn, res.stats.steps,   res.stats.steps_solved,
                res.stats.steps_futile, res.stats.steps_unknown, res.stats.max_steps,
                res.stats.max_steps_turn,
            },
        );
    }
}

// ---------- tests (native: ops/check_solver) ----------

test "the deal is bit-exact with ts/baseline_deal.ts (seed 42)" {
    // Pinned against a TS dump (scratch dump_deal.mjs, 2026-07-23):
    // same mulberry32 stream, same Fisher-Yates, same card order.
    const d = dealGame(42);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "6H QS 6D' TD' 4S' 5C 9D' QC 4C' TH 6C AD' 9C JC 4H'",
        handLine(d.hands[0][0..d.hand_len[0]], &buf),
    );
    try std.testing.expectEqualStrings(
        "TC 2D' 5S' 5H' 2H' 4D TS' KC' JH 7S' KH 9H' QH 8H QC'",
        handLine(d.hands[1][0..d.hand_len[1]], &buf),
    );
    try std.testing.expectEqualStrings(
        "3S' 7D' 7C' 5C' 8H' 6D 4D' 8C' 8S AS'",
        handLine(d.deck[0..10], &buf),
    );
    try std.testing.expectEqual(@as(usize, 51), d.deck_len);
}

test "self-play: six seeds land the pinned games" {
    // The same six seeds as ts/test/test_full_game.ts, identical deals
    // by construction. Aggregates pinned exactly (benchmark pattern:
    // a behavior change fails loud, gets inspected, and re-pins
    // deliberately). Card conservation asserts every turn inside.
    const Pin = struct { seed: u32, turns: u16, p0: u16, p1: u16, stacks: usize };
    const pins = [_]Pin{
        .{ .seed = 42, .turns = 10, .p0 = 30, .p1 = 35, .stacks = 20 },
        .{ .seed = 43, .turns = 10, .p0 = 30, .p1 = 35, .stacks = 20 },
        .{ .seed = 44, .turns = 10, .p0 = 30, .p1 = 35, .stacks = 26 },
        .{ .seed = 100, .turns = 11, .p0 = 30, .p1 = 35, .stacks = 23 },
        .{ .seed = 200, .turns = 10, .p0 = 30, .p1 = 35, .stacks = 21 },
        .{ .seed = 300, .turns = 10, .p0 = 30, .p1 = 35, .stacks = 23 },
    };
    for (pins) |pin| {
        const res = try playGame(pin.seed);
        try std.testing.expectEqual(StopReason.deck_low, res.stopped);
        try std.testing.expectEqual(pin.turns, res.n_turns);
        try std.testing.expectEqual(pin.p0, res.played_total[0]);
        try std.testing.expectEqual(pin.p1, res.played_total[1]);
        try std.testing.expectEqual(@as(u8, 5), res.hand_len[0]);
        try std.testing.expectEqual(@as(u8, 5), res.hand_len[1]);
        try std.testing.expectEqual(@as(u8, 6), res.deck_left);
        try std.testing.expectEqual(pin.stacks, res.board.n_stacks);
        try std.testing.expectEqual(@as(u32, 0), res.stats.probe_unknowns);
    }
}

/// Space-joined ASCII card tokens — the dump/test line format.
pub fn handLine(cards: []const card.Card, buf: []u8) []const u8 {
    var n: usize = 0;
    for (cards, 0..) |c, i| {
        if (i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        var cb: [3]u8 = undefined;
        const t = card.formatCard(c, &cb);
        @memcpy(buf[n .. n + t.len], t);
        n += t.len;
    }
    return buf[0..n];
}
