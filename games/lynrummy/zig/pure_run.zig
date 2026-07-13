//! pure_run — phase 1 of the solver rethink: solve-board when PURE RUNS
//! are the only legal meld. (Phase 2 adds red-black runs; phase 3 sets.)
//!
//! Whether a board can be arranged clean depends only on the card
//! MULTISET — the current stacking matters later, when deriving moves.
//! And with pure runs only, suits never interact, so the board splits
//! into four independent single-suit problems. Each one: given per-value
//! counts c(v) ∈ {0,1,2} on the 13-value cycle (K→A→2 wraps), cover
//! every value exactly c(v) times with arcs of length 3..13 — an arc IS
//! a run, and ≤13 is what keeps its values distinct.
//!
//! The search: take the first value that still needs coverage, try every
//! arc that covers it, recurse. Complete (any solution must cover the
//! pivot somehow), and effectively instant at this size. If a
//! pathological futile board ever shows up, the known upgrade is a
//! failed-state memo — a suit's count vector has at most 3^13 states.

const std = @import("std");
const card = @import("card.zig");

/// One pure run: `len` consecutive ranks of one suit starting at
/// `start`, wrapping mod 13. Deck labels are absent on purpose — see
/// card.zig; assigning them to a legal solution is always possible
/// (the two copies of a rank land in two different arcs).
pub const Arc = struct { suit: u2, start: u4, len: u4 };

pub const MAX_ARCS = card.MAX_CARDS / 3;

pub const Solution = struct {
    arcs: [MAX_ARCS]Arc,
    n: usize,
};

/// solve answers phase-1 solve-board: a clean all-pure-run partition of
/// the multiset, or null. FUTILE is a first-class answer, not an error.
pub fn solve(counts: *const card.Counts) ?Solution {
    var sol: Solution = .{ .arcs = undefined, .n = 0 };
    for (0..4) |suit| {
        var c = counts[suit];
        if (!solveSuit(&c, @intCast(suit), &sol)) return null;
    }
    return sol;
}

fn arcFits(c: *const [13]u8, start: usize, len: usize) bool {
    for (0..len) |i| {
        if (c[(start + i) % 13] == 0) return false;
    }
    return true;
}

fn solveSuit(c: *[13]u8, suit: u2, sol: *Solution) bool {
    const pivot = blk: {
        for (0..13) |v| {
            if (c[v] > 0) break :blk v;
        }
        return true; // every demand met
    };
    var len: usize = 3;
    while (len <= 13) : (len += 1) {
        var off: usize = 0;
        while (off < len) : (off += 1) {
            const start = (pivot + 13 - off) % 13;
            if (!arcFits(c, start, len)) continue;
            for (0..len) |i| c[(start + i) % 13] -= 1;
            sol.arcs[sol.n] = .{ .suit = suit, .start = @intCast(start), .len = @intCast(len) };
            sol.n += 1;
            if (solveSuit(c, suit, sol)) return true;
            sol.n -= 1;
            for (0..len) |i| c[(start + i) % 13] += 1;
        }
    }
    return false;
}

/// verify checks a claimed solution against the input: every arc a legal
/// pure run (length 3..13) and coverage EXACTLY equal to the counts —
/// strict multiset equality, no tolerance.
pub fn verify(counts: *const card.Counts, sol: *const Solution) bool {
    var cover = std.mem.zeroes(card.Counts);
    for (sol.arcs[0..sol.n]) |a| {
        if (a.len < 3) return false;
        for (0..a.len) |i| {
            cover[a.suit][(@as(usize, a.start) + i) % 13] += 1;
        }
    }
    return std.meta.eql(cover, counts.*);
}

// ---------- tests (native: ops/check_solver) ----------
//
// Fixtures are board lines in the human notation ("7H 8H 9H | TC");
// `|` marks are cosmetic. Suits: H,D,C,S; ' = second-deck copy (also
// cosmetic here — only the multiset matters).

fn countsOf(fixture: []const u8) !card.Counts {
    var buf: [card.MAX_CARDS]card.Card = undefined;
    return try card.buildCounts(try card.parseBoard(fixture, &buf));
}

fn expectSolvable(fixture: []const u8) !void {
    const counts = try countsOf(fixture);
    const sol = solve(&counts) orelse {
        std.debug.print("expected solvable, got FUTILE: \"{s}\"\n", .{fixture});
        return error.TestUnexpectedResult;
    };
    if (!verify(&counts, &sol)) {
        std.debug.print("solution fails verify: \"{s}\"\n", .{fixture});
        return error.TestUnexpectedResult;
    }
}

fn expectFutile(fixture: []const u8) !void {
    const counts = try countsOf(fixture);
    if (solve(&counts) != null) {
        std.debug.print("expected FUTILE, got a solution: \"{s}\"\n", .{fixture});
        return error.TestUnexpectedResult;
    }
}

test "solvable boards get verified all-pure-run partitions" {
    const fixtures = [_][]const u8{
        "", // an empty board is already clean
        "3H 4H 5H",
        "QH KH AH", // the wrap
        "KH AH 2H", // the wrap, centered
        "JH QH KH AH 2H", // RULES.md's length-5 wrap example
        "3H 4H 5H 6H 7H 8H 9H", // 7 cards: 3+4, 4+3, or one 7-run
        "3H 4H 5H | TC JC QC KC", // suits are independent
        "5S 5S' 6S 6S' 7S 7S'", // duplicates: two parallel runs
        "4D 5D 5D' 6D 6D' 7D", // staggered: 4-5-6 + 5-6-7
        "AH 2H 3H 4H 5H 6H 7H 8H 9H TH JH QH KH", // one 13-run
        // a 13-run plus a wrap run riding the second deck
        "AH 2H 3H 4H 5H 6H 7H 8H 9H TH JH QH KH | QH' KH' AH'",
        // all 13 hearts + a second ace. Looks futile — it isn't:
        // QKA + A23 share only the ace across the wrap, and 4..J
        // mops up. (The solver caught the author expecting FUTILE.)
        "AH 2H 3H 4H 5H 6H 7H 8H 9H TH JH QH KH | AH'",
    };
    for (fixtures) |f| try expectSolvable(f);
}

test "the full deck is solvable, once and twice over" {
    var counts: card.Counts = undefined;
    for ([_]u8{ 1, 2 }) |copies| {
        counts = .{.{copies} ** 13} ** 4;
        const sol = solve(&counts) orelse return error.TestUnexpectedResult;
        try std.testing.expect(verify(&counts, &sol));
    }
}

test "futile boards report FUTILE" {
    const fixtures = [_][]const u8{
        "8H", // a singleton
        "7H 8H", // a pair
        "5H 7H 9H", // gaps
        "3H 4H 5C", // suits don't mix
        "6H 6H' 7H 8H", // the double 6 demands two runs; only 4 cards
        "3H 4H 5H 6H 6H'", // same shape, other end
        "2C 3C 4C 6C 7C 8C TC", // two clean runs + an orphaned T
        // 3..K once + a second 3: with A and 2 missing there's no wrap
        // to lean on, so both 3s would need runs starting at 3 — and
        // the single 4 can only feed one of them.
        "3H 4H 5H 6H 7H 8H 9H TH JH QH KH | 3H'",
    };
    for (fixtures) |f| try expectFutile(f);
}

test "pinned minimal solutions" {
    // 3H 4H 5H → exactly one arc: hearts, start rank 3, length 3.
    {
        const counts = try countsOf("3H 4H 5H");
        const sol = solve(&counts).?;
        try std.testing.expectEqual(@as(usize, 1), sol.n);
        try std.testing.expectEqual(Arc{ .suit = 0, .start = 2, .len = 3 }, sol.arcs[0]);
    }
    // QH KH AH → one arc that wraps: start Q, length 3 (covers Q, K, A).
    {
        const counts = try countsOf("QH KH AH");
        const sol = solve(&counts).?;
        try std.testing.expectEqual(@as(usize, 1), sol.n);
        try std.testing.expectEqual(Arc{ .suit = 0, .start = 11, .len = 3 }, sol.arcs[0]);
    }
}
