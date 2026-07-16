//! solver — solve-board for the full TWO-DECK game. Melds are RUNS —
//! pure (same suit) or red-black (alternating colors), both stepping
//! rank+1 with the wrap — and SETS: 3 or 4 cards of one rank, distinct
//! suits, color-blind.
//!
//! TWO DECKS: the two copies of a (suit, rank) are indistinguishable to
//! legality — a run can't repeat a value and a set can't repeat a suit,
//! so no meld ever tells them apart. Solvability depends only on the
//! per-card multiplicity, and the search works at (suit, count) level:
//! when a chain grabs "suit s at rank r" it consumes copy 0 before
//! copy 1 (a WLOG rule, not a choice point), and the memo state carries
//! no copy labels, so states differing only in labels merge. Copy
//! identity exists solely in the next-map the solution is written into.
//!
//! The board is the sparse successor map: each card points at the card
//! it grabbed to its right, or at nothing. A clean board = an injective,
//! acyclic next-map whose chains are flavor-uniform and length ≥ 3; a
//! set is a chain whose links stay inside one rank. Runs get NO length
//! cap in the game: a long chain always splits into legal 3..13 display
//! runs, and any ≤13 window is automatically value-repeat-free. Sets
//! can't be repaired after the fact like that — their distinct-SUIT
//! constraint is enforced where they're built, and at two decks it is
//! load-bearing: 7H 7C 7H' is three cards at one rank and still no set.
//!
//! NORMALIZATION LEMMA (load-bearing): the search only builds chains of
//! length 3..5, and that loses nothing — any legal chain splits into
//! consecutive legal chains with lengths in {3,4,5}, so a board is
//! solvable iff it has an all-short solution. The cap is also what
//! keeps a chain from lapping the rank cycle, which the sweep below
//! depends on.
//!
//! THE SWEEP: every run edge steps rank+1, so the 13 ranks are a
//! topological order. Sweep them once, rank by rank; the only live
//! state is the set of OPEN chains — each just (suit at the current
//! rank, flavor, capped length), at most 8 of them (a chain must
//! consume a card at every rank it stays open through, and a rank holds
//! at most 8 cards). At each rank, branch over the ways open chains
//! continue or close and leftover cards form up to two sets (they're
//! rank-local, so they carry no state across ranks) or start fresh
//! chains; memoize futile (rank, state) pairs, which bounds the whole
//! search by the tiny state space. A first cut of chain-growing DFS
//! thrashed for HOURS on dense 40-card boards; this sweep is the
//! eliminate-the-cause fix.
//!
//! THE WRAP: chains may cross the boundary K→A (or wherever we cut).
//! Cut at the boundary entering the scarcest rank and branch over the
//! concrete matchings M of cards that cross it. (That's the budgeted
//! fast path; the rare dense board that grinds retries unbounded from
//! the fewest-matchings cut — the portfolio in solve.) Each M-edge births a
//! chain at sweep start (its head half) whose length is recorded when
//! it closes; at sweep end the still-open chains must feed the M-edges
//! bijectively, with combined head+tail length 3..5. The lemma keeps
//! any chain from crossing the cut twice, so this bookkeeping is whole.

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");
pub const suit_first = @import("suit_first.zig");

pub const Flavor = enum { open, pure, rb, set };

/// The board as a canonical two-deck bitset: bit i (i < 52) = at least
/// one copy of base card i on the board, bit 52+i = a second copy. The
/// high bit implies the low one; deck labels never survive the lowering
/// — solvability depends only on the multiset.
pub const Board = u128;

/// The solved board in the sparse form: next[i] is the card slot that
/// card slot i points at, or NONE at a chain end (and for cards not on
/// the board).
pub const Solution = struct {
    next: [graph.SLOTS]u8,
};

fn bit(i: u8) Board {
    return @as(Board, 1) << @intCast(i);
}

/// boardBits lowers parsed cards to the canonical bitset. Deck marks in
/// fixtures are dressing (the multiset is the content); a third copy of
/// a (suit, rank) fails loud.
pub fn boardBits(cards: []const card.Card) card.Error!Board {
    const counts = try card.buildCounts(cards);
    var bits: Board = 0;
    for (0..4) |s| {
        for (0..13) |r| {
            const base: u8 = @intCast(s * 13 + r);
            if (counts[s][r] >= 1) bits |= bit(base);
            if (counts[s][r] == 2) bits |= bit(base + 52);
        }
    }
    return bits;
}

/// componentsOk: every connected component of the board's meld graph
/// (run edges both ways plus same-rank set mates) must have ≥ 3 cards —
/// a component can't borrow cards from elsewhere, so a small one dooms
/// the board. Necessary, not sufficient: a pure prefilter that answers
/// many futile boards before any cut matching is guessed (each matching
/// re-sweeps with a fresh memo, so global futility would otherwise be
/// re-learned once per matching).
fn componentsOk(board: Board) bool {
    // Copies share all their neighbors, so BFS the base (52-card)
    // projection and weight each card by its multiplicity. (A second
    // copy can't meld with its twin, so multiplicity-weighted size ≥ 3
    // stays merely necessary — which is all a prefilter needs.)
    const present: u64 = @truncate(board); // canonical: high implies low
    var seen: u64 = 0;
    for (0..graph.N) |i| {
        const c: u8 = @intCast(i);
        if (present >> @intCast(c) & 1 == 0 or seen >> @intCast(c) & 1 != 0) continue;
        var stack: [graph.N]u8 = undefined;
        var sp: usize = 1;
        stack[0] = c;
        seen |= @as(u64, 1) << @intCast(c);
        var size: u32 = 0;
        while (sp > 0) {
            sp -= 1;
            const cur = stack[sp];
            size += 1 + @as(u32, @intCast(board >> @intCast(cur + 52) & 1));
            const r = graph.rankOf(cur);
            const su = graph.suitOf(cur);
            const nb = [9]u8{
                graph.succ[cur].pure, graph.succ[cur].rb[0], graph.succ[cur].rb[1],
                graph.pred[cur].pure, graph.pred[cur].rb[0], graph.pred[cur].rb[1],
                ((su + 1) % 4) * 13 + r, ((su + 2) % 4) * 13 + r, ((su + 3) % 4) * 13 + r,
            };
            for (nb) |x| {
                if (present >> @intCast(x) & 1 != 0 and seen >> @intCast(x) & 1 == 0) {
                    seen |= @as(u64, 1) << @intCast(x);
                    stack[sp] = x;
                    sp += 1;
                }
            }
        }
        if (size < 3) return false;
    }
    return true;
}

/// solve answers solve-board: a clean next-map for the card multiset,
/// or null. FUTILE is a first-class answer, not an error.
pub fn solve(board: Board) ?Solution {
    if (!componentsOk(board)) return null;
    // Tier 0: the human prior — pure runs + sets, suit-decomposed
    // (suit_first.zig). Answers most dense boards in microseconds with
    // a human-shaped cover; a pass falls through to the complete sweep.
    {
        var sol: Solution = undefined;
        if (suit_first.trySolve(board, &sol.next)) return sol;
    }
    // Per rank: an 8-bit SLOT mask — low nibble copy 0 of suits 0-3,
    // high nibble copy 1. Canonical board keeps high implying low
    // within each rank.
    var at: [13]u8 = @splat(0);
    for (0..graph.N) |i| {
        const c: u8 = @intCast(i);
        if (board & bit(c) != 0) at[graph.rankOf(c)] |= @as(u8, 1) << @intCast(graph.suitOf(c));
        if (board & bit(c + 52) != 0) at[graph.rankOf(c)] |= @as(u8, 1) << @intCast(graph.suitOf(c) + 4);
    }
    // Portfolio. Fast path: cut entering the scarcest rank, under a
    // step budget that 99.9% of boards never approach (tail boards run
    // ~300k steps; typical boards run hundreds).
    var r0: u8 = 0;
    for (1..13) |r| {
        if (@popCount(at[r]) < @popCount(at[r0])) r0 = @intCast(r);
    }
    steps_left = 50_000;
    var s = Sweeper.init(at, r0);
    if (s.enumMFrom()) return .{ .next = s.next };
    if (steps_left >= 0) return null; // search completed: honest FUTILE
    // Budget tripped: a tail board. Retry unbounded from the cut with
    // the fewest concrete wrap matchings (tie: fewest target cards) —
    // matchings are what tail boards grind on.
    var rb: u8 = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..13) |r| {
        const cnt = countMAt(at, @intCast(r));
        const score = (cnt << 4) | @popCount(at[r]);
        if (score < best) {
            best = score;
            rb = @intCast(r);
        }
    }
    steps_left = std.math.maxInt(i64);
    var s2 = Sweeper.init(at, rb);
    if (s2.enumMFrom()) return .{ .next = s2.next };
    return null;
}

// Step budget for the portfolio fast path (see solve). A tripped budget
// makes every step return false immediately and suppresses memoization —
// truncated exploration must not record futility facts.
var steps_left: i64 = std.math.maxInt(i64);

/// instances expands a rank's slot mask into target instances, suits
/// adjacent (suit 0 copy 0, suit 0 copy 1, suit 1 copy 0, …) — the
/// matching enumeration's copy-symmetry rules lean on that adjacency.
fn instances(mask: u8, out: *[8]u8) []const u8 {
    var n: usize = 0;
    for (0..4) |s| {
        if (mask >> @intCast(s) & 1 != 0) {
            out[n] = @intCast(s);
            n += 1;
        }
        if (mask >> @intCast(s + 4) & 1 != 0) {
            out[n] = @intCast(s + 4);
            n += 1;
        }
    }
    return out[0..n];
}

fn suitCounts(mask: u8) [4]u8 {
    var cnt: [4]u8 = @splat(0);
    for (0..4) |s| {
        cnt[s] = (mask >> @intCast(s) & 1) + (mask >> @intCast(s + 4) & 1);
    }
    return cnt;
}

/// countMAt: the exact number of complete cut matchings enumM would try
/// for the cut entering rank r — used to pick the fallback cut. Mirrors
/// enumM's canonicalization, so the count is honest.
fn countMAt(at: [13]u8, r: u8) u64 {
    var tb: [8]u8 = undefined;
    const tgts = instances(at[r], &tb);
    const src_cnt = suitCounts(at[(r + 12) % 13]);
    var src_used: [4]u8 = @splat(0);
    return countM(tgts, 0, 0, &src_cnt, &src_used);
}

fn countM(tgts: []const u8, ti: usize, pair_min: i8, src_cnt: *const [4]u8, src_used: *[4]u8) u64 {
    if (ti == tgts.len) return 1;
    const slot = tgts[ti];
    const t: u8 = slot & 3;
    const partnered = slot >= 4; // canonical: its copy-0 twin sits at ti-1
    var n: u64 = countM(tgts, ti + 1, -1, src_cnt, src_used); // not crossed
    if (partnered and pair_min < 0) return n;
    var x: u8 = if (partnered) @intCast(pair_min) else 0;
    while (x < 4) : (x += 1) {
        if (src_used[x] == src_cnt[x]) continue;
        if (x != t and (x < 2) == (t < 2)) continue; // same color, diff suit
        src_used[x] += 1;
        n += countM(tgts, ti + 1, @intCast(x), src_cnt, src_used);
        src_used[x] -= 1;
    }
    return n;
}

const MAX_OPEN = 8; // two decks: at most 8 cards per rank

/// An open chain, described by its card at the current sweep rank. The
/// copy bit exists only to address the next-map; it stays out of the
/// memo key, so states differing in copy labels merge.
const Open = struct {
    suit: u8,
    copy: u8,
    flavor: Flavor,
    len: u8, // fresh: cards so far; M-born: head cards so far
    m_idx: i8, // -1 = fresh, else index into m_edges
};

/// A guessed cut-crossing edge: some suit-x card at rank vL → the card
/// at slot y of rank r0. The source stays a suit, not a slot — the
/// concrete source card is wherever the feeding chain actually ends,
/// bound at matchEnd time.
const MEdge = struct {
    x_suit: u8,
    y_slot: u8,
    flavor: Flavor,
};

// Futile (rank, state) keys for the current M guess. A slot is live
// only when its epoch stamp matches the current sweep's — so clearing
// the table between matchings is one integer increment. (Memsetting
// the 2MB table per matching put a flat ~ms floor under EVERY swept
// board, dwarfing the real search on small ones — the scale probe
// found it.) Collisions just skip memoization — correctness never
// depends on the table.
// Sized from one-deck measurement: the densest solvable boards reached
// ~90k distinct futile states per matching; 2^18 holds that with room
// (4MB of u128 keys + 1MB of epochs, static). Two-deck probes will say
// whether it still fits.
const MEMO_BITS = 18;
var memo_table: [1 << MEMO_BITS]u128 = undefined;
var memo_epoch: [1 << MEMO_BITS]u32 = @splat(0); // 0 = never used
var epoch: u32 = 0;

/// nextEpoch invalidates the whole table in O(1). The u32 wrap (once
/// per ~4 billion sweeps) triggers the one honest full reset.
fn nextEpoch() void {
    epoch +%= 1;
    if (epoch == 0) {
        @memset(&memo_epoch, 0);
        epoch = 1;
    }
}

/// suitsPresent projects a rank's slot mask down to the suits with at
/// least one card left.
fn suitsPresent(avail: u8) u8 {
    return (avail | (avail >> 4)) & 0xF;
}

/// concreteSlots binds a suit mask to concrete slots in avail, copy 0
/// first — the WLOG materialization rule.
fn concreteSlots(avail: u8, suit_mask: u8) u8 {
    var slots: u8 = 0;
    var m = suit_mask;
    while (m != 0) {
        const s: u8 = @intCast(@ctz(m));
        m &= m - 1;
        slots |= if (avail >> @intCast(s) & 1 != 0)
            @as(u8, 1) << @intCast(s)
        else
            @as(u8, 1) << @intCast(s + 4);
    }
    return slots;
}

/// A carving of sets out of one rank: concrete slot masks; b == 0 means
/// a single set.
const SetPair = struct { a: u8, b: u8 };

/// setPairs: the ways to carve one or two sets out of a rank's
/// available slots — a set takes 3 or 4 DISTINCT suits (the two-deck
/// load-bearing rule); 8 cards can hold two sets. The pair is
/// unordered, so the second suit mask never exceeds the first and the
/// swap symmetry never branches. (Feasibility is order-free: a suit
/// serves two sets only via its two copies.)
fn setPairs(avail: u8, buf: *[30]SetPair) []const SetPair {
    var n: usize = 0;
    const suits1 = suitsPresent(avail);
    var m1 = suits1;
    while (true) {
        if (@popCount(m1) >= 3) {
            const a = concreteSlots(avail, m1);
            buf[n] = .{ .a = a, .b = 0 };
            n += 1;
            const avail2 = avail & ~a;
            const suits2 = suitsPresent(avail2);
            var m2 = suits2;
            while (true) {
                if (@popCount(m2) >= 3 and m2 <= m1) {
                    buf[n] = .{ .a = a, .b = concreteSlots(avail2, m2) };
                    n += 1;
                }
                if (m2 == 0) break;
                m2 = (m2 - 1) & suits2;
            }
        }
        if (m1 == 0) break;
        m1 = (m1 - 1) & suits1;
    }
    return buf[0..n];
}

const Sweeper = struct {
    at: [13]u8,
    r0: u8,
    tgt: [8]u8 = undefined, // target instances at r0, suits adjacent
    tgt_n: u8 = 0,
    src_cnt: [4]u8, // per-suit supply at rank vL
    src_used: [4]u8 = @splat(0),
    next: [graph.SLOTS]u8 = undefined,
    m_edges: [MAX_OPEN]MEdge = undefined,
    m_n: u8 = 0,
    mrec: [MAX_OPEN]u8 = undefined, // closed head lengths; 0 = pending
    open: [MAX_OPEN]Open = undefined,
    open_n: u8 = 0,

    fn init(at: [13]u8, r0: u8) Sweeper {
        var s: Sweeper = .{
            .at = at,
            .r0 = r0,
            .src_cnt = suitCounts(at[(r0 + 12) % 13]),
        };
        var tb: [8]u8 = undefined;
        const tgts = instances(at[r0], &tb);
        @memcpy(s.tgt[0..tgts.len], tgts);
        s.tgt_n = @intCast(tgts.len);
        return s;
    }

    fn rankAt(self: *const Sweeper, pos: u8) u8 {
        return (self.r0 + pos) % 13;
    }

    fn cardOf(rank: u8, suit: u8, copy: u8) u8 {
        return copy * 52 + suit * 13 + rank;
    }

    fn cardOfSlot(rank: u8, slot: u8) u8 {
        return (slot >> 2) * 52 + (slot & 3) * 13 + rank;
    }

    fn enumMFrom(self: *Sweeper) bool {
        return self.enumM(0, 0);
    }

    /// enumM branches over the matchings across the cut: each card at
    /// rank r0 is either not crossed into, or crossed into by some card
    /// of a legal suit with supply left at rank vL. Sources are suits
    /// (counts), not cards — inherently canonical. Copy symmetry on the
    /// target side is broken by two rules keyed on the suit-adjacent
    /// instance order: a copy-1 instance may cross only if its copy-0
    /// twin crossed (pair_min < 0 says it didn't), and then only from a
    /// source suit ≥ the twin's (pair_min carries it). Every complete
    /// guess runs a sweep.
    fn enumM(self: *Sweeper, ti: u8, pair_min: i8) bool {
        if (ti == self.tgt_n) return self.trySweep();
        const slot = self.tgt[ti];
        const t: u8 = slot & 3;
        const partnered = slot >= 4;
        if (self.enumM(ti + 1, -1)) return true; // not crossed
        if (partnered and pair_min < 0) return false;
        var x: u8 = if (partnered) @intCast(pair_min) else 0;
        while (x < 4) : (x += 1) {
            if (self.src_used[x] == self.src_cnt[x]) continue;
            const flavor: Flavor = if (x == t)
                .pure
            else if (graph.isRed(x) != graph.isRed(t))
                .rb
            else
                continue; // same color, different suit: no edge
            self.m_edges[self.m_n] = .{ .x_suit = x, .y_slot = slot, .flavor = flavor };
            self.m_n += 1;
            self.src_used[x] += 1;
            if (self.enumM(ti + 1, @intCast(x))) return true;
            self.src_used[x] -= 1;
            self.m_n -= 1;
        }
        return false;
    }

    fn trySweep(self: *Sweeper) bool {
        self.next = @splat(graph.NONE);
        self.mrec = @splat(0);
        nextEpoch();
        // Rank r0 is consumed at birth: M-edge heads, then the rest
        // form up to two sets or start fresh chains.
        var born: u8 = 0;
        for (self.m_edges[0..self.m_n], 0..) |e, i| {
            self.open[i] = .{
                .suit = e.y_slot & 3,
                .copy = e.y_slot >> 2,
                .flavor = e.flavor,
                .len = 1,
                .m_idx = @intCast(i),
            };
            born |= @as(u8, 1) << @intCast(e.y_slot);
        }
        const rest = self.at[self.r0] & ~born;
        if (self.birthAndStep(rest)) return true;
        var sbuf: [30]SetPair = undefined;
        for (setPairs(rest, &sbuf)) |sp| {
            self.linkSet(self.r0, sp.a, true);
            self.linkSet(self.r0, sp.b, true);
            if (self.birthAndStep(rest & ~(sp.a | sp.b))) return true;
            self.linkSet(self.r0, sp.b, false);
            self.linkSet(self.r0, sp.a, false);
        }
        return false;
    }

    /// birthAndStep: the given r0 card slots start fresh chains alongside
    /// the already-born M-edge heads, and the sweep advances into rank 1.
    fn birthAndStep(self: *Sweeper, fresh: u8) bool {
        self.open_n = self.m_n;
        var rest = fresh;
        while (rest != 0) {
            const slot: u8 = @intCast(@ctz(rest));
            rest &= rest - 1;
            self.open[self.open_n] = .{
                .suit = slot & 3,
                .copy = slot >> 2,
                .flavor = .open,
                .len = 1,
                .m_idx = -1,
            };
            self.open_n += 1;
        }
        return self.step(1);
    }

    fn step(self: *Sweeper, pos: u8) bool {
        steps_left -= 1;
        if (steps_left < 0) return false; // budget tripped: unwind fast
        if (pos == 13) return self.finish();
        const key = self.encode(pos);
        if (memoHas(key)) return false;
        var new_open: [MAX_OPEN]Open = undefined;
        if (self.assign(pos, 0, self.at[self.rankAt(pos)], &new_open, 0)) return true;
        if (steps_left < 0) return false; // truncated: not a futility fact
        memoAdd(key);
        return false;
    }

    /// assign decides, for open chain ci at rank position pos, whether it
    /// closes or which card it grabs; past the last chain, leftover cards
    /// form up to two sets or start fresh chains and the sweep advances.
    /// Continued and fresh chains accumulate in new_open, one buffer per
    /// rank frame.
    fn assign(self: *Sweeper, pos: u8, ci: u8, avail: u8, new_open: *[MAX_OPEN]Open, new_n: u8) bool {
        if (ci == self.open_n) {
            if (self.freshAndStep(pos, avail, new_open, new_n)) return true;
            var sbuf: [30]SetPair = undefined;
            for (setPairs(avail, &sbuf)) |sp| {
                self.linkSet(self.rankAt(pos), sp.a, true);
                self.linkSet(self.rankAt(pos), sp.b, true);
                if (self.freshAndStep(pos, avail & ~(sp.a | sp.b), new_open, new_n)) return true;
                self.linkSet(self.rankAt(pos), sp.b, false);
                self.linkSet(self.rankAt(pos), sp.a, false);
            }
            return false;
        }
        const c = self.open[ci];
        // Option: close the chain at the previous rank.
        if (c.m_idx >= 0) {
            self.mrec[@intCast(c.m_idx)] = c.len;
            if (self.assign(pos, ci + 1, avail, new_open, new_n)) return true;
            self.mrec[@intCast(c.m_idx)] = 0;
        } else if (c.len >= 3) {
            if (self.assign(pos, ci + 1, avail, new_open, new_n)) return true;
        }
        // Option: grab a card at this rank. M-born heads stop at 4 (the
        // tail contributes at least 1); fresh chains stop at 5. Copies
        // never branch: the suit's copy-0 slot is consumed first, WLOG.
        const cap: u8 = if (c.m_idx >= 0) 4 else 5;
        if (c.len >= cap) return false;
        const r = self.rankAt(pos);
        const prev = cardOf(self.rankAt(pos - 1), c.suit, c.copy);
        var suits = suitsPresent(avail);
        while (suits != 0) {
            const s: u8 = @intCast(@ctz(suits));
            suits &= suits - 1;
            const f: Flavor = if (s == c.suit)
                .pure
            else if (graph.isRed(s) != graph.isRed(c.suit))
                .rb
            else
                continue;
            if (c.flavor != .open and c.flavor != f) continue;
            const slot: u8 = if (avail >> @intCast(s) & 1 != 0) s else s + 4;
            self.next[prev] = cardOfSlot(r, slot);
            new_open[new_n] = .{ .suit = s, .copy = slot >> 2, .flavor = f, .len = c.len + 1, .m_idx = c.m_idx };
            if (self.assign(pos, ci + 1, avail & ~(@as(u8, 1) << @intCast(slot)), new_open, new_n + 1)) return true;
            self.next[prev] = graph.NONE;
        }
        return false;
    }

    /// freshAndStep: the leftover card slots at this rank start fresh
    /// chains, the new frontier replaces the old, and the sweep advances.
    fn freshAndStep(self: *Sweeper, pos: u8, avail: u8, new_open: *[MAX_OPEN]Open, new_n: u8) bool {
        var nn = new_n;
        var rest = avail;
        while (rest != 0) {
            const slot: u8 = @intCast(@ctz(rest));
            rest &= rest - 1;
            new_open[nn] = .{
                .suit = slot & 3,
                .copy = slot >> 2,
                .flavor = .open,
                .len = 1,
                .m_idx = -1,
            };
            nn += 1;
        }
        const saved_open = self.open;
        const saved_n = self.open_n;
        self.open = new_open.*;
        self.open_n = nn;
        const ok = self.step(pos + 1);
        self.open = saved_open;
        self.open_n = saved_n;
        return ok;
    }

    /// linkSet writes (or unwinds) the same-rank links of one set,
    /// ascending by suit. The slot mask holds at most one slot per suit
    /// (a set never repeats a suit).
    fn linkSet(self: *Sweeper, rank: u8, slots: u8, link: bool) void {
        var prev: u8 = 0xFF;
        for (0..4) |s| {
            const su: u8 = @intCast(s);
            const slot: u8 = if (slots >> @intCast(s) & 1 != 0)
                su
            else if (slots >> @intCast(s + 4) & 1 != 0)
                su + 4
            else
                continue;
            if (prev != 0xFF) {
                self.next[cardOfSlot(rank, prev)] = if (link) cardOfSlot(rank, slot) else graph.NONE;
            }
            prev = slot;
        }
    }

    /// finish: after the last rank, every M-born head must have closed,
    /// and the still-open chains close (length ≥ 3) or feed the M-edges
    /// bijectively with combined head+tail length 3..5.
    fn finish(self: *Sweeper) bool {
        for (self.open[0..self.open_n]) |c| {
            if (c.m_idx >= 0) return false; // a head reaching the cut would lap
        }
        return self.matchEnd(0, 0);
    }

    fn matchEnd(self: *Sweeper, ci: u8, used: u8) bool {
        if (ci == self.open_n) {
            // The glue edges were written on the way down.
            return @popCount(used) == self.m_n;
        }
        const c = self.open[ci];
        if (c.len >= 3 and self.matchEnd(ci + 1, used)) return true;
        // The chain's actual end card is the edge's concrete source —
        // writing the glue from it keeps copy binding consistent.
        const end = cardOf(self.rankAt(12), c.suit, c.copy);
        for (self.m_edges[0..self.m_n], 0..) |e, i| {
            if (used & (@as(u8, 1) << @intCast(i)) != 0) continue;
            if (e.x_suit != c.suit) continue;
            if (c.flavor != .open and c.flavor != e.flavor) continue;
            const total = c.len + self.mrec[i];
            if (total < 3 or total > 5) continue;
            self.next[end] = cardOfSlot(self.r0, e.y_slot);
            if (self.matchEnd(ci + 1, used | (@as(u8, 1) << @intCast(i)))) return true;
            self.next[end] = graph.NONE;
        }
        return false;
    }

    /// encode packs (pos, sorted open chains, recorded head lengths)
    /// into the memo key. 11 bits per chain, 3 per head record, 4 for
    /// pos: 116 bits. Copy labels stay out — states differing only in
    /// them are the same state.
    fn encode(self: *const Sweeper, pos: u8) u128 {
        var chains: [MAX_OPEN]u16 = @splat(0);
        for (self.open[0..self.open_n], 0..) |c, i| {
            chains[i] = (@as(u16, c.suit) << 9) |
                (@as(u16, @intFromEnum(c.flavor)) << 7) |
                (@as(u16, c.len) << 4) |
                @as(u16, @intCast(c.m_idx + 1));
        }
        std.mem.sort(u16, chains[0..self.open_n], {}, std.sort.asc(u16));
        var key: u128 = pos;
        for (chains) |ch| key = (key << 11) | ch;
        for (self.mrec) |h| key = (key << 3) | h;
        return key;
    }
};

/// memoSlot: Fibonacci hash — the raw key's low bits are the least
/// variable part (mrec records, often all zero), so `key % len` would
/// cluster nearly every key onto slot 0 and reduce the table to its
/// 8-probe window. Multiply-and-take-top-bits mixes every key bit in;
/// the two u128 halves get distinct odd multipliers.
fn memoSlot(key: u128) u64 {
    const lo: u64 = @truncate(key);
    const hi: u64 = @truncate(key >> 64);
    return ((lo *% 0x9E3779B97F4A7C15) ^ (hi *% 0xC2B2AE3D27D4EB4F)) >> (64 - MEMO_BITS);
}

fn memoHas(key: u128) bool {
    var slot = memoSlot(key);
    for (0..8) |_| {
        if (memo_epoch[slot] != epoch) return false; // empty this sweep
        if (memo_table[slot] == key) return true;
        slot = (slot + 1) % memo_table.len;
    }
    return false;
}

fn memoAdd(key: u128) void {
    var slot = memoSlot(key);
    for (0..8) |_| {
        if (memo_epoch[slot] != epoch or memo_table[slot] == key) {
            memo_table[slot] = key;
            memo_epoch[slot] = epoch;
            return;
        }
        slot = (slot + 1) % memo_table.len;
    }
    // probe run full: skip memoizing this key
}

// ---------- verification (strict, independent of the search) ----------

fn edgeFlavor(a: u8, b: u8) ?Flavor {
    // rankOf/suitOf are copy-blind, so the two copies of one card
    // compare as same rank AND same suit — no edge of any flavor.
    if (graph.rankOf(a) == graph.rankOf(b)) {
        return if (graph.suitOf(a) != graph.suitOf(b)) .set else null;
    }
    if (graph.rankOf(b) != (graph.rankOf(a) + 1) % 13) return null;
    if (graph.suitOf(a) == graph.suitOf(b)) return .pure;
    if (graph.isRed(graph.suitOf(a)) != graph.isRed(graph.suitOf(b))) return .rb;
    return null; // same color, different suit: no such run edge
}

/// verify checks a claimed next-map against the board: edges legal and
/// flavor-uniform per chain, no card grabbed twice, no cycles, every
/// chain length ≥ 3, no set repeating a suit (the two-deck load-bearing
/// rule), every board card in exactly one chain.
pub fn verify(board: Board, sol: *const Solution) bool {
    var indeg = [_]u8{0} ** graph.SLOTS;
    for (0..graph.SLOTS) |i| {
        const c: u8 = @intCast(i);
        const n = sol.next[i];
        if (board & bit(c) == 0) {
            if (n != graph.NONE) return false;
            continue;
        }
        if (n == graph.NONE) continue;
        if (n >= graph.SLOTS or board & bit(n) == 0) return false;
        if (edgeFlavor(c, n) == null) return false;
        if (indeg[n] != 0) return false;
        indeg[n] = 1;
    }
    var covered: u32 = 0;
    for (0..graph.SLOTS) |i| {
        const c: u8 = @intCast(i);
        if (board & bit(c) == 0 or indeg[c] != 0) continue;
        // c starts a chain: walk it.
        var flavor: ?Flavor = null;
        var set_suits: u8 = @as(u8, 1) << @intCast(graph.suitOf(c));
        var len: u32 = 1;
        var cur = c;
        while (sol.next[cur] != graph.NONE) {
            const nx = sol.next[cur];
            const f = edgeFlavor(cur, nx).?;
            if (flavor) |have| {
                if (have != f) return false;
            } else flavor = f;
            if (f == .set) {
                const sb = @as(u8, 1) << @intCast(graph.suitOf(nx));
                if (set_suits & sb != 0) return false; // 7H=7C=7H' is no set
                set_suits |= sb;
            }
            cur = nx;
            len += 1;
        }
        if (len < 3) return false;
        covered += len;
    }
    // Cycles have no start, so their cards are never walked: catch them
    // by demanding full coverage.
    return covered == @popCount(board);
}

/// format renders a solution in the human notation, chains sorted by
/// their start card; run links print as '>' and set links as '=', and
/// second-deck copies carry their ' mark:
/// "3H>4S>5H | 9C>TC'>JC | KH=KC=KS".
pub fn format(board: Board, sol: *const Solution, buf: []u8) []const u8 {
    var indeg = [_]u8{0} ** graph.SLOTS;
    for (0..graph.SLOTS) |i| {
        if (sol.next[i] != graph.NONE) indeg[sol.next[i]] = 1;
    }
    var n: usize = 0;
    var first_chain = true;
    for (0..graph.SLOTS) |i| {
        const c: u8 = @intCast(i);
        if (board & bit(c) == 0 or indeg[c] != 0) continue;
        if (!first_chain) {
            @memcpy(buf[n .. n + 3], " | ");
            n += 3;
        }
        first_chain = false;
        var cur = c;
        while (true) {
            var cb: [3]u8 = undefined;
            const s = card.formatCard(.{
                .rank = @intCast(graph.rankOf(cur)),
                .suit = @intCast(graph.suitOf(cur)),
                .deck = @intCast(cur / 52),
            }, &cb);
            @memcpy(buf[n .. n + s.len], s);
            n += s.len;
            const nx = sol.next[cur];
            if (nx == graph.NONE) break;
            buf[n] = if (graph.rankOf(nx) == graph.rankOf(cur)) '=' else '>';
            n += 1;
            cur = nx;
        }
    }
    return buf[0..n];
}

// ---------- tests (native: ops/check_solver) ----------
//
// Fixtures are board lines in the human notation; `|` marks are
// cosmetic and deck marks are dressing ("3H 3H" and "3H 3H'" lower to
// the same multiset). A third copy of a card is a fixture bug and
// fails loud.

fn bitsOf(fixture: []const u8) !Board {
    var buf: [card.MAX_CARDS]card.Card = undefined;
    return try boardBits(try card.parseBoard(fixture, &buf));
}

fn expectSolvable(fixture: []const u8) !void {
    const board = try bitsOf(fixture);
    const sol = solve(board) orelse {
        std.debug.print("expected solvable, got FUTILE: \"{s}\"\n", .{fixture});
        return error.TestUnexpectedResult;
    };
    if (!verify(board, &sol)) {
        var fb: [512]u8 = undefined;
        std.debug.print("solution fails verify: \"{s}\" → \"{s}\"\n", .{ fixture, format(board, &sol, &fb) });
        return error.TestUnexpectedResult;
    }
}

fn expectFutile(fixture: []const u8) !void {
    const board = try bitsOf(fixture);
    if (solve(board)) |sol| {
        var fb: [512]u8 = undefined;
        std.debug.print("expected FUTILE, got: \"{s}\" → \"{s}\"\n", .{ fixture, format(board, &sol, &fb) });
        return error.TestUnexpectedResult;
    }
}

test "solvable boards get verified next-maps" {
    const fixtures = [_][]const u8{
        "", // an empty board is already clean
        "3H 4H 5H", // pure, as before
        "3H 4S 5H", // minimal rb — FUTILE under phase 1, alive now
        "3H 4S 5D", // rb with three suits: colors alternate, suits roam
        "QH KS AD", // rb through the wrap
        "QH KS AD 2C 3H", // rb riding the wrap, length 5
        "4H 5H 6H | 5S 6D 7S", // one pure + one rb, sharing a value range
        // one long rb snake (14 cards, the value 'A' appearing twice —
        // fine in runs); the solver emits it split into short chains
        "AH 2S 3D 4C 5H 6S 7D 8C 9H TS JD QC KH AS",
        "7H 7S 7C", // the minimal set
        "7H 7D 7C 7S", // a full set of four
        "3H 4H 5H | KH KC KS", // a run and a set, no interaction
        // 3H is claimed by the run, the other three 3s form the set —
        // the greedy set of all four 3s must be backed out of
        "3H 3D 3C 3S 4H 5H",
        // a set sitting on the K rank while a pure run rides the wrap
        "QD KD AD | KH KS KC",
        // sets or rb runs — two different full covers exist
        "AH AS AC 2H 2S 2C 3H 3S 3C",
    };
    for (fixtures) |f| try expectSolvable(f);
}

test "the full one-deck board is solvable" {
    const board: Board = (1 << graph.N) - 1;
    const sol = solve(board) orelse return error.TestUnexpectedResult;
    try std.testing.expect(verify(board, &sol));
}

test "futile boards report FUTILE" {
    const fixtures = [_][]const u8{
        "8H", // a singleton
        "7H 8S", // a pair
        "3H 4H 5S", // pure then rb: chains may not change flavor
        "3H 4D 5H", // all red, no shared suit, no rank triple
        "3H 4H 5H | 9C TC", // a stranded pair
        "2H 3H 4H 4S", // the extra 4S has no third card to meld with
        // every 3-chain cover of 4H strands the rest — real backtracking
        "4H 4S 5S 5D 6D 6H",
        "7H 7S 8C", // connected (set link + rb link) but coverable by nothing
        // the mirror of the solvable contention board: with only three
        // 3s, the set and the run both want 3H
        "3H 3S 3C 4H 5H",
    };
    for (fixtures) |f| try expectFutile(f);
}

test "the component prefilter is necessary, not sufficient" {
    // A stranded pair fails the prefilter outright…
    try std.testing.expect(!componentsOk(try bitsOf("3H 4H 5H | 9C TC")));
    // …but a connected futile board sails through it (3H-4H is a pure
    // edge, 4H-5S is rb — one component, still no solution) and must be
    // answered by the sweep.
    const connected_futile = try bitsOf("3H 4H 5S");
    try std.testing.expect(componentsOk(connected_futile));
    try std.testing.expectEqual(@as(?Solution, null), solve(connected_futile));
}

test "a stranded card inside a big board is caught fast" {
    // All hearts + all diamonds except 2D and 4D: with no black cards on
    // the board, 3D has no rb neighbors and its pure neighbors are gone.
    // Sets don't rescue it either — no rank has more than two cards.
    const board = try bitsOf(
        "AH 2H 3H 4H 5H 6H 7H 8H 9H TH JH QH KH | AD 3D 5D 6D 7D 8D 9D TD JD QD KD",
    );
    try std.testing.expectEqual(@as(?Solution, null), solve(board));
}

test "dense random boards that thrashed the chain-growing search" {
    // Both found by the random-board probe: the first hung the naive
    // chain DFS for 6+ CPU-minutes, the second survived the 3..5 cap
    // and hung anyway. The sweep answers both instantly.
    // 41 cards. FUTILE under phase-2 runs-only (oracle-confirmed);
    // sets are exactly what it was missing — solvable since phase 3.
    const thrash1: u64 = 0xdffb7bb6efe3f;
    if (solve(thrash1)) |sol| {
        try std.testing.expect(verify(thrash1, &sol));
    } else return error.TestUnexpectedResult;
    // 45 cards, solvable with runs alone already.
    const thrash2: u64 = 0xf6ffb7bff9fff;
    if (solve(thrash2)) |sol| {
        try std.testing.expect(verify(thrash2, &sol));
    } else return error.TestUnexpectedResult;
}

test "dense boards that exposed the memo hash clustering" {
    // Found by the phase-3 timing probe: with `key % len` slotting,
    // nearly every memo key hashed to slot 0 and these ran as raw DFS —
    // 274s and 3.2s respectively. With honest hashing both answer in
    // milliseconds (2-4k distinct futile states, table holds 32k).
    const monster: u64 = 0x3ff977fff6fef; // 43 cards
    if (solve(monster)) |sol| {
        try std.testing.expect(verify(monster, &sol));
    } else return error.TestUnexpectedResult;
    // The futile one matters more: FUTILE is the exhaustive case, so
    // it's the one that degrades when memoization quietly dies.
    const grinder: u64 = 0xd3f2fbcde9bfe; // 37 cards
    try std.testing.expectEqual(@as(?Solution, null), solve(grinder));
}

test "tier 0 reproduces Steve's human solution on the 45-card monster" {
    // The timing probe's all-time worst board cost the sweep a full
    // second (~300k steps, 7 wrong wrap matchings refuted); served as
    // a gallery puzzle, Steve solved it in trivial time — six pure
    // runs (hearts going around the ace) plus the keystone ace set,
    // A♠ being the one card with no pure neighbors. The suit-first
    // tier finds exactly that cover, in microseconds.
    const monster: u64 = 0x7fcbffffdfefb;
    const sol = solve(monster) orelse return error.TestUnexpectedResult;
    try std.testing.expect(verify(monster, &sol));
    var fb: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "4H>5H>6H>7H>8H | TH>JH>QH>KH>AH>2H | AD=AC=AS | 2D>3D>4D" ++
            " | 6D>7D>8D>9D>TD>JD>QD>KD | 2C>3C>4C>5C>6C>7C>8C>9C>TC>JC>QC" ++
            " | 4S>5S>6S>7S>8S>9S>TS>JS>QS",
        format(monster, &sol, &fb),
    );
}

test "a weave-heavy board passes tier 0 and rides the sweep's fallback" {
    // 44 cards; the suit-first prior can't cover it (its sweep answer
    // leans on eight red-black weaves), and the scarcest-rank cut
    // trips the step budget — so this one board exercises tier-0
    // pass-through, the budget trip, AND the fewest-matchings retry.
    const weaver: u64 = 0xff9cff9fffbfe;
    const sol = solve(weaver) orelse return error.TestUnexpectedResult;
    try std.testing.expect(verify(weaver, &sol));
}

test "pinned minimal solutions" {
    // 3H 4S 5H has exactly one clean arrangement.
    {
        const board = try bitsOf("3H 4S 5H");
        const sol = solve(board).?;
        var fb: [512]u8 = undefined;
        try std.testing.expectEqualStrings("3H>4S>5H", format(board, &sol, &fb));
    }
    // So does 3H 4H 5H.
    {
        const board = try bitsOf("3H 4H 5H");
        const sol = solve(board).?;
        var fb: [512]u8 = undefined;
        try std.testing.expectEqualStrings("3H>4H>5H", format(board, &sol, &fb));
    }
    // And the minimal set, printed with set links ascending by suit.
    {
        const board = try bitsOf("7H 7S 7C");
        const sol = solve(board).?;
        var fb: [512]u8 = undefined;
        try std.testing.expectEqualStrings("7H=7C=7S", format(board, &sol, &fb));
    }
}

test "fixture bugs fail loud: a third copy of a card" {
    var buf: [card.MAX_CARDS]card.Card = undefined;
    try std.testing.expectError(
        error.TooManyCopies,
        boardBits(try card.parseBoard("3H 3H 3H'", &buf)),
    );
}

test "two decks: copies of one card can never share a meld" {
    const fixtures = [_][]const u8{
        // One component by multiplicity (so the prefilter passes), but
        // the copies can't run together and no rank has three suits.
        "7H 7H' 8H",
        // THE load-bearing case: three cards at one rank, no set —
        // a set may not repeat a suit.
        "7H 7C 7H'",
        // The set of three forms, but its leftover copy strands.
        "7H 7C 7S 7H'",
        // The run forms; the extra 4H has nowhere to go.
        "3H 4H 4H' 5H",
    };
    for (fixtures) |f| try expectFutile(f);
}

test "two decks: parallel structures solve" {
    const fixtures = [_][]const u8{
        "3H 3H' 4H 4H' 5H 5H'", // two parallel pure runs
        "QH QH' KH KH' AH AH'", // both riding the wrap
        "3H 3H' 4S 4S' 5H 5H'", // two parallel rb runs
        "7H 7H' 7C 7C' 7S 7S'", // two sets at one rank
        "7H 7D 7C 7S 7H' 7D' 7C' 7S'", // two full sets of four
        "3H 4H' 5H", // deck marks are dressing: the 3H 4H 5H multiset
        // the set takes the first copies, the run borrows the second
        "6H 7H 8H 7H' 7C 7S",
        // a doubled rank feeding one set and two crossing runs
        "6H 6D 7H 7D 7H' 7D' 7C 8H 8D",
    };
    for (fixtures) |f| try expectSolvable(f);
}

test "two decks: the full 104-card board is eight parallel 13-runs" {
    const board: Board = (@as(Board, 1) << 104) - 1;
    const sol = solve(board) orelse return error.TestUnexpectedResult;
    try std.testing.expect(verify(board, &sol));
    // Tier 0 answers this human-shaped: per suit and copy, one pure
    // A..K run — no set, no red-black weave anywhere.
    for (0..2) |d| {
        for (0..4) |s| {
            const base: u8 = @intCast(d * 52 + s * 13);
            for (0..12) |r| {
                try std.testing.expectEqual(base + @as(u8, @intCast(r)) + 1, sol.next[base + r]);
            }
            try std.testing.expectEqual(graph.NONE, sol.next[base + 12]);
        }
    }
}

test "two decks: the staircase gets overlapping pure runs, not sets" {
    const board = try bitsOf("3H 4H 4H' 5H 5H' 6H");
    const sol = solve(board).?;
    var fb: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "3H>4H>5H | 4H'>5H'>6H",
        format(board, &sol, &fb),
    );
}

test "two decks: pinned parallel-set solution" {
    const board = try bitsOf("7H 7H' 7C 7C' 7S 7S'");
    const sol = solve(board).?;
    var fb: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "7H=7C=7S | 7H'=7C'=7S'",
        format(board, &sol, &fb),
    );
}
