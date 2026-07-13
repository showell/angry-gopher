//! solver — phase 3 of the solver rethink: solve-board for the full
//! one-deck game. Melds are RUNS — pure (same suit) or red-black
//! (alternating colors), both stepping rank+1 with the wrap — and SETS:
//! 3 or 4 cards of one rank, distinct suits, color-blind.
//!
//! The board is the sparse successor map: each card points at the card
//! it grabbed to its right, or at nothing. A clean board = an injective,
//! acyclic next-map whose chains are flavor-uniform and length ≥ 3; a
//! set is a chain whose links stay inside one rank. Runs get NO length
//! cap in the game: a long chain always splits into legal 3..13 display
//! runs, and any ≤13 window is automatically value-repeat-free. Sets
//! can't be repaired after the fact like that — their distinct-card
//! constraint is enforced where they're built (trivially here: one deck
//! holds at most 4 cards of a rank; it turns load-bearing at two decks).
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
//! rank, flavor, capped length), at most 4 of them (a chain must
//! consume a card at every rank it stays open through). At each rank,
//! branch over the ways open chains continue or close and leftover
//! cards form at most one set (they're rank-local, so they carry no
//! state across ranks) or start fresh chains; memoize futile
//! (rank, state) pairs, which bounds the whole search by the tiny state
//! space. A first cut of chain-growing DFS thrashed for HOURS on dense
//! 40-card boards; this sweep is the eliminate-the-cause fix.
//!
//! THE WRAP: chains may cross the boundary K→A (or wherever we cut).
//! Cut at the boundary entering the scarcest rank and branch over the
//! concrete matchings M of cards that cross it. Each M-edge births a
//! chain at sweep start (its head half) whose length is recorded when
//! it closes; at sweep end the still-open chains must feed the M-edges
//! bijectively, with combined head+tail length 3..5. The lemma keeps
//! any chain from crossing the cut twice, so this bookkeeping is whole.

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");

pub const Error = error{ OneDeckOnly, DuplicateCard };

pub const Flavor = enum { open, pure, rb, set };

/// The solved board in the sparse form: next[i] is the card index that
/// card i points at, or NONE at a chain end (and for cards not on the
/// board).
pub const Solution = struct {
    next: [graph.N]u8,
};

fn bit(i: u8) u64 {
    return @as(u64, 1) << @intCast(i);
}

/// boardBits lowers parsed cards to the one-deck bitset, failing loud on
/// second-deck marks and on the same card twice.
pub fn boardBits(cards: []const card.Card) Error!u64 {
    var bits: u64 = 0;
    for (cards) |c| {
        if (c.deck != 0) return error.OneDeckOnly;
        const i = graph.cardIndex(c);
        if (bits & bit(i) != 0) return error.DuplicateCard;
        bits |= bit(i);
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
fn componentsOk(board: u64) bool {
    var seen: u64 = 0;
    for (0..graph.N) |i| {
        const c: u8 = @intCast(i);
        if (board & bit(c) == 0 or seen & bit(c) != 0) continue;
        var stack: [graph.N]u8 = undefined;
        var sp: usize = 1;
        stack[0] = c;
        seen |= bit(c);
        var size: u32 = 0;
        while (sp > 0) {
            sp -= 1;
            const cur = stack[sp];
            size += 1;
            const r = graph.rankOf(cur);
            const su = graph.suitOf(cur);
            const nb = [9]u8{
                graph.succ[cur].pure, graph.succ[cur].rb[0], graph.succ[cur].rb[1],
                graph.pred[cur].pure, graph.pred[cur].rb[0], graph.pred[cur].rb[1],
                ((su + 1) % 4) * 13 + r, ((su + 2) % 4) * 13 + r, ((su + 3) % 4) * 13 + r,
            };
            for (nb) |x| {
                if (board & bit(x) != 0 and seen & bit(x) == 0) {
                    seen |= bit(x);
                    stack[sp] = x;
                    sp += 1;
                }
            }
        }
        if (size < 3) return false;
    }
    return true;
}

/// solve answers phase-2 solve-board: a clean all-runs next-map for the
/// card set, or null. FUTILE is a first-class answer, not an error.
pub fn solve(board: u64) ?Solution {
    if (!componentsOk(board)) return null;
    var at: [13]u8 = @splat(0); // suit mask per rank
    for (0..graph.N) |i| {
        const c: u8 = @intCast(i);
        if (board & bit(c) != 0) at[graph.rankOf(c)] |= @as(u8, 1) << @intCast(graph.suitOf(c));
    }
    // Cut entering the scarcest rank: fewest cards = fewest M guesses.
    var r0: u8 = 0;
    for (1..13) |r| {
        if (@popCount(at[r]) < @popCount(at[r0])) r0 = @intCast(r);
    }
    var s: Sweeper = .{ .at = at, .r0 = r0 };
    if (!s.enumM(at[r0], at[(r0 + 12) % 13])) return null;
    return .{ .next = s.next };
}

const MAX_OPEN = 4; // one deck: at most 4 cards per rank

/// An open chain, described by its card at the current sweep rank.
const Open = struct {
    suit: u8,
    flavor: Flavor,
    len: u8, // fresh: cards so far; M-born: head cards so far
    m_idx: i8, // -1 = fresh, else index into m_edges
};

/// A guessed cut-crossing edge: card (vL, x_suit) → card (r0, y_suit).
const MEdge = struct {
    x_suit: u8,
    y_suit: u8,
    flavor: Flavor,
};

// Futile (rank, state) keys for the current M guess. Zero = empty slot;
// keys are never zero (pos ≥ 1 sits in the low bits). Collisions just
// skip memoization — correctness never depends on the table.
var memo_table: [1 << 15]u64 = undefined;

/// setMasks: the ways to carve one set out of the available suits at a
/// rank — any 3 or 4 of them; sets ignore color. One deck holds at most
/// 4 cards of a rank, so at most one set fits and 5 masks bound it.
fn setMasks(avail: u8, buf: *[5]u8) []const u8 {
    var n: usize = 0;
    var m = avail;
    while (true) {
        if (@popCount(m) >= 3) {
            buf[n] = m;
            n += 1;
        }
        if (m == 0) break;
        m = (m - 1) & avail;
    }
    return buf[0..n];
}

const Sweeper = struct {
    at: [13]u8,
    r0: u8,
    next: [graph.N]u8 = undefined,
    m_edges: [MAX_OPEN]MEdge = undefined,
    m_n: u8 = 0,
    m_used_src: u8 = 0,
    mrec: [MAX_OPEN]u8 = undefined, // closed head lengths; 0 = pending
    open: [MAX_OPEN]Open = undefined,
    open_n: u8 = 0,

    fn rankAt(self: *const Sweeper, pos: u8) u8 {
        return (self.r0 + pos) % 13;
    }

    fn cardOf(rank: u8, suit: u8) u8 {
        return suit * 13 + rank;
    }

    /// enumM branches over the concrete matchings across the cut: each
    /// card at rank r0 is either not crossed into, or crossed into by a
    /// legal, unused card at rank vL. Every complete guess runs a sweep.
    fn enumM(self: *Sweeper, targets: u8, sources: u8) bool {
        if (targets == 0) return self.trySweep();
        const t: u8 = @intCast(@ctz(targets));
        const rest = targets & (targets - 1);
        if (self.enumM(rest, sources)) return true;
        var srcs = sources & ~self.m_used_src;
        while (srcs != 0) {
            const x: u8 = @intCast(@ctz(srcs));
            srcs &= srcs - 1;
            const flavor: Flavor = if (x == t)
                .pure
            else if (graph.isRed(x) != graph.isRed(t))
                .rb
            else
                continue; // same color, different suit: no edge
            self.m_edges[self.m_n] = .{ .x_suit = x, .y_suit = t, .flavor = flavor };
            self.m_n += 1;
            self.m_used_src |= @as(u8, 1) << @intCast(x);
            if (self.enumM(rest, sources)) return true;
            self.m_used_src &= ~(@as(u8, 1) << @intCast(x));
            self.m_n -= 1;
        }
        return false;
    }

    fn trySweep(self: *Sweeper) bool {
        self.next = @splat(graph.NONE);
        self.mrec = @splat(0);
        @memset(&memo_table, 0);
        // Rank r0 is consumed at birth: M-edge heads, then the rest
        // form at most one set or start fresh chains.
        var born: u8 = 0;
        for (self.m_edges[0..self.m_n], 0..) |e, i| {
            self.open[i] = .{
                .suit = e.y_suit,
                .flavor = e.flavor,
                .len = 1,
                .m_idx = @intCast(i),
            };
            born |= @as(u8, 1) << @intCast(e.y_suit);
        }
        const rest = self.at[self.r0] & ~born;
        if (self.birthAndStep(rest)) return true;
        var sbuf: [5]u8 = undefined;
        for (setMasks(rest, &sbuf)) |sm| {
            self.linkSet(self.r0, sm, true);
            if (self.birthAndStep(rest & ~sm)) return true;
            self.linkSet(self.r0, sm, false);
        }
        return false;
    }

    /// birthAndStep: the given r0 cards start fresh chains alongside the
    /// already-born M-edge heads, and the sweep advances into rank 1.
    fn birthAndStep(self: *Sweeper, fresh: u8) bool {
        self.open_n = self.m_n;
        var rest = fresh;
        while (rest != 0) {
            const s: u8 = @intCast(@ctz(rest));
            rest &= rest - 1;
            self.open[self.open_n] = .{ .suit = s, .flavor = .open, .len = 1, .m_idx = -1 };
            self.open_n += 1;
        }
        return self.step(1);
    }

    fn step(self: *Sweeper, pos: u8) bool {
        if (pos == 13) return self.finish();
        const key = self.encode(pos);
        if (memoHas(key)) return false;
        var new_open: [MAX_OPEN]Open = undefined;
        if (self.assign(pos, 0, self.at[self.rankAt(pos)], &new_open, 0)) return true;
        memoAdd(key);
        return false;
    }

    /// assign decides, for open chain ci at rank position pos, whether it
    /// closes or which card it grabs; past the last chain, leftover cards
    /// form at most one set or start fresh chains and the sweep advances.
    /// Continued and fresh chains accumulate in new_open, one buffer per
    /// rank frame.
    fn assign(self: *Sweeper, pos: u8, ci: u8, avail: u8, new_open: *[MAX_OPEN]Open, new_n: u8) bool {
        if (ci == self.open_n) {
            if (self.freshAndStep(pos, avail, new_open, new_n)) return true;
            var sbuf: [5]u8 = undefined;
            for (setMasks(avail, &sbuf)) |sm| {
                self.linkSet(self.rankAt(pos), sm, true);
                if (self.freshAndStep(pos, avail & ~sm, new_open, new_n)) return true;
                self.linkSet(self.rankAt(pos), sm, false);
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
        // tail contributes at least 1); fresh chains stop at 5.
        const cap: u8 = if (c.m_idx >= 0) 4 else 5;
        if (c.len >= cap) return false;
        const r = self.rankAt(pos);
        const prev = cardOf(self.rankAt(pos - 1), c.suit);
        var suits = avail;
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
            self.next[prev] = cardOf(r, s);
            new_open[new_n] = .{ .suit = s, .flavor = f, .len = c.len + 1, .m_idx = c.m_idx };
            if (self.assign(pos, ci + 1, avail & ~(@as(u8, 1) << @intCast(s)), new_open, new_n + 1)) return true;
            self.next[prev] = graph.NONE;
        }
        return false;
    }

    /// freshAndStep: the leftover cards at this rank start fresh chains,
    /// the new frontier replaces the old, and the sweep advances.
    fn freshAndStep(self: *Sweeper, pos: u8, avail: u8, new_open: *[MAX_OPEN]Open, new_n: u8) bool {
        var nn = new_n;
        var rest = avail;
        while (rest != 0) {
            const s: u8 = @intCast(@ctz(rest));
            rest &= rest - 1;
            new_open[nn] = .{ .suit = s, .flavor = .open, .len = 1, .m_idx = -1 };
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
    /// ascending by suit.
    fn linkSet(self: *Sweeper, rank: u8, mask: u8, link: bool) void {
        var m = mask;
        var prev: u8 = 0xFF;
        while (m != 0) {
            const s: u8 = @intCast(@ctz(m));
            m &= m - 1;
            if (prev != 0xFF) {
                self.next[cardOf(rank, prev)] = if (link) cardOf(rank, s) else graph.NONE;
            }
            prev = s;
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
            if (@popCount(used) != self.m_n) return false;
            // Success: write the glue edges across the cut.
            const vl = self.rankAt(12);
            for (self.m_edges[0..self.m_n]) |e| {
                self.next[cardOf(vl, e.x_suit)] = cardOf(self.r0, e.y_suit);
            }
            return true;
        }
        const c = self.open[ci];
        if (c.len >= 3 and self.matchEnd(ci + 1, used)) return true;
        for (self.m_edges[0..self.m_n], 0..) |e, i| {
            if (used & (@as(u8, 1) << @intCast(i)) != 0) continue;
            if (e.x_suit != c.suit) continue;
            if (c.flavor != .open and c.flavor != e.flavor) continue;
            const total = c.len + self.mrec[i];
            if (total < 3 or total > 5) continue;
            if (self.matchEnd(ci + 1, used | (@as(u8, 1) << @intCast(i)))) return true;
        }
        return false;
    }

    /// encode packs (pos, sorted open chains, recorded head lengths)
    /// into the memo key. 10 bits per chain, 3 per head record, 4 for
    /// pos: 56 bits.
    fn encode(self: *const Sweeper, pos: u8) u64 {
        var chains: [MAX_OPEN]u16 = @splat(0);
        for (self.open[0..self.open_n], 0..) |c, i| {
            chains[i] = (@as(u16, c.suit) << 8) |
                (@as(u16, @intFromEnum(c.flavor)) << 6) |
                (@as(u16, c.len) << 3) |
                @as(u16, @intCast(c.m_idx + 1));
        }
        std.mem.sort(u16, chains[0..self.open_n], {}, std.sort.asc(u16));
        var key: u64 = pos;
        for (chains) |ch| key = (key << 10) | ch;
        for (self.mrec) |h| key = (key << 3) | h;
        return key;
    }
};

/// memoSlot: Fibonacci hash — the raw key's low bits are the least
/// variable part (mrec records, often all zero), so `key % len` would
/// cluster nearly every key onto slot 0 and reduce the table to its
/// 8-probe window. Multiply-and-take-top-bits mixes every key bit in.
fn memoSlot(key: u64) u64 {
    return (key *% 0x9E3779B97F4A7C15) >> (64 - 15);
}

fn memoHas(key: u64) bool {
    var slot = memoSlot(key);
    for (0..8) |_| {
        if (memo_table[slot] == key) return true;
        if (memo_table[slot] == 0) return false;
        slot = (slot + 1) % memo_table.len;
    }
    return false;
}

fn memoAdd(key: u64) void {
    var slot = memoSlot(key);
    for (0..8) |_| {
        if (memo_table[slot] == 0 or memo_table[slot] == key) {
            memo_table[slot] = key;
            return;
        }
        slot = (slot + 1) % memo_table.len;
    }
    // probe run full: skip memoizing this key
}

// ---------- verification (strict, independent of the search) ----------

fn edgeFlavor(a: u8, b: u8) ?Flavor {
    if (graph.rankOf(a) == graph.rankOf(b)) {
        // Same rank: a set link — unless it's the same card.
        return if (graph.suitOf(a) != graph.suitOf(b)) .set else null;
    }
    if (graph.rankOf(b) != (graph.rankOf(a) + 1) % 13) return null;
    if (graph.suitOf(a) == graph.suitOf(b)) return .pure;
    if (graph.isRed(graph.suitOf(a)) != graph.isRed(graph.suitOf(b))) return .rb;
    return null; // same color, different suit: no such run edge
}

/// verify checks a claimed next-map against the board: edges legal and
/// flavor-uniform per chain, no card grabbed twice, no cycles, every
/// chain length ≥ 3, every board card in exactly one chain.
pub fn verify(board: u64, sol: *const Solution) bool {
    var indeg = [_]u8{0} ** graph.N;
    for (0..graph.N) |i| {
        const c: u8 = @intCast(i);
        const n = sol.next[i];
        if (board & bit(c) == 0) {
            if (n != graph.NONE) return false;
            continue;
        }
        if (n == graph.NONE) continue;
        if (n >= graph.N or board & bit(n) == 0) return false;
        if (edgeFlavor(c, n) == null) return false;
        if (indeg[n] != 0) return false;
        indeg[n] = 1;
    }
    var covered: u32 = 0;
    for (0..graph.N) |i| {
        const c: u8 = @intCast(i);
        if (board & bit(c) == 0 or indeg[c] != 0) continue;
        // c starts a chain: walk it.
        var flavor: ?Flavor = null;
        var len: u32 = 1;
        var cur = c;
        while (sol.next[cur] != graph.NONE) {
            const nx = sol.next[cur];
            const f = edgeFlavor(cur, nx).?;
            if (flavor) |have| {
                if (have != f) return false;
            } else flavor = f;
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
/// their start card; run links print as '>' and set links as '=':
/// "3H>4S>5H | 9C>TC>JC | KH=KC=KS".
pub fn format(board: u64, sol: *const Solution, buf: []u8) []const u8 {
    var indeg = [_]u8{0} ** graph.N;
    for (0..graph.N) |i| {
        if (sol.next[i] != graph.NONE) indeg[sol.next[i]] = 1;
    }
    var n: usize = 0;
    var first_chain = true;
    for (0..graph.N) |i| {
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
                .deck = 0,
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
// cosmetic. One deck: a `'` card or a repeated card is a fixture bug
// and fails loud.

fn bitsOf(fixture: []const u8) !u64 {
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
    const board: u64 = (1 << graph.N) - 1;
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

test "fixture bugs fail loud: second deck and duplicates" {
    var buf: [card.MAX_CARDS]card.Card = undefined;
    try std.testing.expectError(
        error.OneDeckOnly,
        boardBits(try card.parseBoard("3H 4H' 5H", &buf)),
    );
    try std.testing.expectError(
        error.DuplicateCard,
        boardBits(try card.parseBoard("3H 3H 4H", &buf)),
    );
}
