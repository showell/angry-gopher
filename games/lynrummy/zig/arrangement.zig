//! arrangement — the actual board: an ordered list of STACKS, not just
//! the card multiset. The notation is the solver's own output language:
//! a stack is card tokens glued with `>` (run link) or `=` (set link),
//! stacks are separated by whitespace, and `|` stays cosmetic — so a
//! plain board line like "3H 4H 5H" parses as three singleton stacks
//! (the degenerate arrangement with the same multiset meaning it always
//! had), and a formatted cover round-trips.
//!
//! Stacks are VALID or the parse fails loud: every link must be a legal
//! meld edge, the flavor is uniform per stack (`3H>4S>5H` is rb
//! throughout; `3H>4H=4D` is no stack), the link mark must match the
//! edge (`7H=8H` lies), sets can't repeat a suit, and runs can't repeat
//! a value. Length is the ONE relaxation: a 1-stack is a loose card and
//! a 2-stack is one card short of a meld — `AH=AD` is fine, `AH 7C`
//! only ever arrives as two singletons because no legal link joins them.

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");

pub const Error = card.Error || error{BadStack};

pub const MAX_STACKS = card.MAX_CARDS;

pub const Arrangement = struct {
    cards: [card.MAX_CARDS]card.Card,
    /// Stack i is cards[start[i]..start[i + 1]].
    start: [MAX_STACKS + 1]u8,
    n_stacks: usize,

    pub fn stackCards(self: *const Arrangement, i: usize) []const card.Card {
        return self.cards[self.start[i]..self.start[i + 1]];
    }

    pub fn nCards(self: *const Arrangement) usize {
        return self.start[self.n_stacks];
    }
};

/// parse reads a whole arrangement line. Also validates the multiset
/// (a third copy of a (suit, rank) fails loud, as everywhere).
pub fn parse(line: []const u8) Error!Arrangement {
    var arr: Arrangement = undefined;
    arr.n_stacks = 0;
    arr.start[0] = 0;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t|");
    while (it.next()) |tok| {
        const first = n;
        var seps: [card.MAX_CARDS]u8 = undefined;
        var n_seps: usize = 0;
        var rest = tok;
        while (true) {
            const link = std.mem.indexOfAny(u8, rest, ">=");
            const ctok = if (link) |k| rest[0..k] else rest;
            if (n == card.MAX_CARDS) return error.TooManyCards;
            // A trailing or doubled mark leaves an empty ctok: loud.
            arr.cards[n] = try card.parseCard(ctok);
            n += 1;
            const k = link orelse break;
            seps[n_seps] = rest[k];
            n_seps += 1;
            rest = rest[k + 1 ..];
        }
        try validateStack(arr.cards[first..n], seps[0..n_seps]);
        arr.n_stacks += 1;
        arr.start[arr.n_stacks] = @intCast(n);
    }
    _ = try card.buildCounts(arr.cards[0..n]);
    return arr;
}

/// One stack's legality: every link a legal edge wearing the right mark
/// (`=` iff set), flavor uniform, sets never repeating a suit, runs
/// never repeating a value. Length itself is unconstrained — 1- and
/// 2-stacks are just short.
fn validateStack(cards: []const card.Card, seps: []const u8) Error!void {
    var flavor: ?graph.EdgeFlavor = null;
    var suits: u8 = @as(u8, 1) << cards[0].suit;
    var ranks: u16 = @as(u16, 1) << cards[0].rank;
    for (cards[1..], seps, 1..) |c, sep, i| {
        const f = graph.edgeFlavor(
            graph.cardIndex(cards[i - 1]),
            graph.cardIndex(c),
        ) orelse return error.BadStack;
        if ((sep == '=') != (f == .set)) return error.BadStack;
        if (flavor) |have| {
            if (have != f) return error.BadStack;
        } else flavor = f;
        if (f == .set) {
            const sb = @as(u8, 1) << c.suit;
            if (suits & sb != 0) return error.BadStack;
            suits |= sb;
        } else {
            const rb = @as(u16, 1) << c.rank;
            if (ranks & rb != 0) return error.BadStack;
            ranks |= rb;
        }
    }
}

// ---------- the warm view: what the search can try to keep ----------

/// Warm is the arrangement lowered to the counts the solver's priors
/// consume. Copies are indistinguishable to legality, so warmth lives
/// at (suit, rank) level: a doubled stack pair warms an edge twice.
pub const Warm = struct {
    /// [from suit][r][to suit]: warm run edges rank r → r+1 (mod 13),
    /// count 0..2. Pure edges sit on the diagonal (from == to); rb
    /// edges off it. Tier 0 reads only the diagonal (it builds no rb
    /// runs); the sweep reads the whole row.
    runs: [4][13][4]u8,
    /// Input set-stack suit masks per rank. 2-stacks belong here too:
    /// a same-rank pair is a set one card short.
    set_masks: [13][4]u8,
    set_n: [13]u8,

    pub const EMPTY: Warm = .{
        .runs = @splat(@splat(@splat(0))),
        .set_masks = @splat(@splat(0)),
        .set_n = @splat(0),
    };
};

pub fn warmOf(arr: *const Arrangement) Warm {
    var w = Warm.EMPTY;
    for (0..arr.n_stacks) |si| {
        const cs = arr.stackCards(si);
        if (cs.len < 2) continue;
        const f = graph.edgeFlavor(graph.cardIndex(cs[0]), graph.cardIndex(cs[1])).?;
        if (f == .set) {
            var m: u8 = 0;
            for (cs) |c| m |= @as(u8, 1) << c.suit;
            const r = cs[0].rank;
            w.set_masks[r][w.set_n[r]] = m;
            w.set_n[r] += 1;
        } else {
            for (cs[0 .. cs.len - 1], cs[1..]) |a, b| {
                w.runs[a.suit][a.rank][b.suit] += 1;
            }
        }
    }
    return w;
}

/// How many of the player's warm set pairs the candidate sets (a, b —
/// suit masks) would break at this rank: the same co-membership greedy
/// reportKept scores, so orderings that consult it chase the reported
/// metric. 0 when warm is empty at the rank.
pub fn brokenSetPairs(warm: *const Warm, rank: u8, a: u8, b: u8) u8 {
    var broken: u8 = 0;
    var rem = [2]u8{ a, b };
    for (warm.set_masks[rank][0..warm.set_n[rank]]) |m| {
        var pairs: u8 = @popCount(m) - 1;
        if (@popCount(m & rem[1]) > @popCount(m & rem[0]))
            std.mem.swap(u8, &rem[0], &rem[1]);
        for (&rem) |*o| {
            const ov: u8 = @popCount(m & o.*);
            if (ov >= 2) pairs -= @min(pairs, ov - 1);
            o.* &= ~m;
        }
        broken += pairs;
    }
    return broken;
}

// ---------- the kept/broken report ----------

pub const Fate = enum { intact, partial, shattered };

/// What a cover did to the player's stacks. Edges are the metric
/// (Steve's call): a run link is kept when the cover realizes that
/// (suit, rank) adjacency — copies are dressing, counts are honest —
/// and a set link is kept as CO-MEMBERSHIP: both suits landing in one
/// output set at that rank, chain order irrelevant. Singleton stacks
/// have no edges and are trivially intact.
pub const Report = struct {
    kept_edges: u16,
    total_edges: u16,
    fate: [MAX_STACKS]Fate,
};

pub fn reportKept(arr: *const Arrangement, next: *const [graph.SLOTS]u8) Report {
    // Realized run edges, count-aware: [from base][to suit] = 0..2.
    var run_real: [graph.N][4]u8 = @splat(@splat(0));
    // Output sets per rank as suit masks (≤ 2 sets at two decks).
    var set_out: [13][2]u8 = @splat(.{ 0, 0 });
    var set_out_n: [13]u8 = @splat(0);
    var set_in: [graph.SLOTS]bool = @splat(false);
    for (0..graph.SLOTS) |i| {
        const b = next[i];
        if (b == graph.NONE) continue;
        const a: u8 = @intCast(i);
        if (graph.rankOf(a) == graph.rankOf(b)) {
            set_in[b] = true;
        } else {
            run_real[i % 52][graph.suitOf(b)] += 1;
        }
    }
    for (0..graph.SLOTS) |i| {
        const a: u8 = @intCast(i);
        const b = next[i];
        if (b == graph.NONE or set_in[a] or graph.rankOf(a) != graph.rankOf(b)) continue;
        // a heads a set chain: collect its suits.
        var mask: u8 = 0;
        var cur = a;
        while (true) {
            mask |= @as(u8, 1) << @intCast(graph.suitOf(cur));
            const nx = next[cur];
            if (nx == graph.NONE or graph.rankOf(nx) != graph.rankOf(cur)) break;
            cur = nx;
        }
        const r = graph.rankOf(a);
        std.debug.assert(set_out_n[r] < 2);
        set_out[r][set_out_n[r]] = mask;
        set_out_n[r] += 1;
    }
    var rep: Report = .{ .kept_edges = 0, .total_edges = 0, .fate = undefined };
    for (0..arr.n_stacks) |si| {
        const cs = arr.stackCards(si);
        if (cs.len == 1) {
            rep.fate[si] = .intact;
            continue;
        }
        const f = graph.edgeFlavor(graph.cardIndex(cs[0]), graph.cardIndex(cs[1])).?;
        const total: u16 = @intCast(cs.len - 1);
        var kept: u16 = 0;
        if (f == .set) {
            var m: u8 = 0;
            for (cs) |c| m |= @as(u8, 1) << c.suit;
            // Greedy larger-overlap-first, consuming globally so two
            // input stacks can't both claim one output suit.
            const r = cs[0].rank;
            const rem = &set_out[r];
            if (@popCount(m & rem[1]) > @popCount(m & rem[0]))
                std.mem.swap(u8, &rem[0], &rem[1]);
            for (rem) |*o| {
                const ov: u16 = @popCount(m & o.*);
                if (ov >= 2) kept += ov - 1;
                o.* &= ~m;
            }
        } else {
            for (cs[0 .. cs.len - 1], cs[1..]) |a, b| {
                const cnt = &run_real[@as(usize, a.suit) * 13 + a.rank][b.suit];
                if (cnt.* > 0) {
                    cnt.* -= 1;
                    kept += 1;
                }
            }
        }
        rep.kept_edges += kept;
        rep.total_edges += total;
        rep.fate[si] = if (kept == total) .intact else if (kept > 0) .partial else .shattered;
    }
    return rep;
}

// ---------- tests (native: ops/check_solver) ----------

test "a formatted cover parses back into its stacks" {
    const arr = try parse("3H>4S>5H | 9C>TC'>JC | KH=KC=KS");
    try std.testing.expectEqual(@as(usize, 3), arr.n_stacks);
    for (0..3) |i| try std.testing.expectEqual(@as(usize, 3), arr.stackCards(i).len);
    try std.testing.expectEqual(@as(u1, 1), arr.stackCards(1)[1].deck); // TC'
    try std.testing.expectEqual(@as(usize, 9), arr.nCards());
}

test "plain board lines are the degenerate all-singletons arrangement" {
    const arr = try parse("3H 4H 5H");
    try std.testing.expectEqual(@as(usize, 3), arr.n_stacks);
    for (0..3) |i| try std.testing.expectEqual(@as(usize, 1), arr.stackCards(i).len);
    try std.testing.expectEqual(@as(usize, 0), (try parse("")).n_stacks);
}

test "2-stacks: one card short of a meld is a valid stack" {
    for ([_][]const u8{ "AH=AD", "QD>KS", "4C>5C", "QH>KH>AH" }) |line| {
        const arr = try parse(line);
        try std.testing.expectEqual(@as(usize, 1), arr.n_stacks);
    }
}

test "invalid stacks fail loud" {
    for ([_][]const u8{
        "AH>7C", // no legal edge at all
        "AH=7C", // set mark across ranks
        "7H=8H", // run edge wearing a set mark
        "7H>7C", // set edge wearing a run mark
        "3H>4D", // same color, different suit: no run edge
        "3H>4H=4D", // mixed flavor
        "7H=7C=7H'", // set repeats a suit
        "KH=KC=KS=KD=KH'", // five cards can't keep suits distinct
    }) |line| {
        try std.testing.expectError(error.BadStack, parse(line));
    }
}

test "a run stack can wrap K to A but never repeat a value" {
    _ = try parse("JH>QH>KH>AH>2H");
    // The full 13-run is legal; gluing its wrap edge closes the cycle
    // and repeats the value — no stack.
    _ = try parse("AH>2H>3H>4H>5H>6H>7H>8H>9H>TH>JH>QH>KH");
    try std.testing.expectError(
        error.BadStack,
        parse("AH>2H>3H>4H>5H>6H>7H>8H>9H>TH>JH>QH>KH>AH'"),
    );
}

test "the multiset stays honest: a third copy fails loud" {
    try std.testing.expectError(error.TooManyCopies, parse("7H>8H 7H'>8H' 7H"));
}

test "warmOf: pure edges on the diagonal, rb off it, sets mask" {
    const arr = try parse("3H>4H>5H 3H'>4H' AH=AD 4C>5D>6C");
    const w = warmOf(&arr);
    try std.testing.expectEqual(@as(u8, 2), w.runs[0][2][0]); // 3H>4H doubled
    try std.testing.expectEqual(@as(u8, 1), w.runs[0][3][0]); // 4H>5H once
    try std.testing.expectEqual(@as(u8, 1), w.set_n[0]);
    try std.testing.expectEqual(@as(u8, 0b0011), w.set_masks[0][0]); // {H,D}
    // The rb stack warms its off-diagonal edges.
    try std.testing.expectEqual(@as(u8, 1), w.runs[2][3][1]); // 4C>5D
    try std.testing.expectEqual(@as(u8, 1), w.runs[1][4][2]); // 5D>6C
    try std.testing.expectEqual(@as(u8, 0), w.runs[2][3][2]);
}

/// A next-map built from one arrangement line — for report tests, the
/// cover IS a (fully melded) arrangement.
fn nextOf(line: []const u8) ![graph.SLOTS]u8 {
    const arr = try parse(line);
    var next: [graph.SLOTS]u8 = @splat(graph.NONE);
    var used: [graph.N]u8 = @splat(0);
    var slots: [card.MAX_CARDS]u8 = undefined;
    for (0..arr.n_stacks) |si| {
        const cs = arr.stackCards(si);
        for (cs, 0..) |c, i| {
            // First-come copy assignment, like the solver's builders.
            const base = @as(u8, c.suit) * 13 + c.rank;
            slots[i] = base + used[base] * 52;
            used[base] += 1;
        }
        for (0..cs.len -| 1) |i| next[slots[i]] = slots[i + 1];
    }
    return next;
}

test "report: kept, partial, shattered" {
    const arr = try parse("3H>4H>5H KH=KC 9C>TC");
    // A cover keeping the heart run, splitting the kings across sets
    // (KH with spades' set... KC elsewhere), and breaking the club run.
    const next = try nextOf("3H>4H>5H>6H KH=KS=KD KC=KD'=KS' 7C>8C>9C TC>JC>QC");
    const rep = reportKept(&arr, &next);
    try std.testing.expectEqual(Fate.intact, rep.fate[0]); // 3H>4H>5H rode along
    try std.testing.expectEqual(Fate.shattered, rep.fate[1]); // KH,KC in different sets
    try std.testing.expectEqual(Fate.shattered, rep.fate[2]); // 9C|TC split
    try std.testing.expectEqual(@as(u16, 2), rep.kept_edges);
    try std.testing.expectEqual(@as(u16, 4), rep.total_edges);
}

test "report: set co-membership ignores chain order" {
    const arr = try parse("KH=KS");
    const next = try nextOf("KH=KC=KS 3H>4H>5H");
    const rep = reportKept(&arr, &next);
    try std.testing.expectEqual(Fate.intact, rep.fate[0]);
    try std.testing.expectEqual(@as(u16, 1), rep.kept_edges);
}

test "report: singletons are trivially intact with no edges" {
    const arr = try parse("3H 4H 5H");
    const next = try nextOf("3H>4H>5H");
    const rep = reportKept(&arr, &next);
    for (0..3) |i| try std.testing.expectEqual(Fate.intact, rep.fate[i]);
    try std.testing.expectEqual(@as(u16, 0), rep.total_edges);
}

test "report: two input pairs cannot both claim one output suit" {
    // Both input pairs are {H,D} at rank K; the cover holds one K set
    // containing H and D once. Only one pair's edge is kept.
    const arr = try parse("KH=KD KH'=KD'");
    const next = try nextOf("KH=KD=KC 3H>4H>5H");
    const rep = reportKept(&arr, &next);
    try std.testing.expectEqual(@as(u16, 1), rep.kept_edges);
    try std.testing.expectEqual(@as(u16, 2), rep.total_edges);
}
