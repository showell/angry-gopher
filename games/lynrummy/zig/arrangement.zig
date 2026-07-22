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
