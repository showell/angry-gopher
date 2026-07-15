//! graph — the successor graph over the 52 distinct (suit, rank) cards,
//! precomputed at comptime like the knight-move table in
//! games/chess/knight.zig. Base index = suit*13 + rank (suits H,D,C,S;
//! H,D red); the second deck's copy of base card i lives at SLOT i+52,
//! and rankOf/suitOf are copy-blind — no meld ever distinguishes the
//! two copies of a (suit, rank), so the tables stay 52 wide. Every run
//! edge steps rank+1 mod 13 — the K→A→2 wrap is just the modulus. Two
//! run flavors, and they are DISJOINT (a same-suit step is same-color,
//! so it can never be an rb step — a chain's flavor is decided by its
//! first edge):
//!
//!   pure — same suit:            exactly 1 successor per card
//!   rb   — opposite color:       exactly 2 successors per card

const std = @import("std");
const card = @import("card.zig");

pub const N = 52; // distinct (suit, rank) cards; tables are this wide
pub const SLOTS = 104; // both copies; slot = deck*52 + suit*13 + rank
pub const NONE: u8 = 0xFF;

pub fn cardIndex(c: card.Card) u8 {
    return @as(u8, c.deck) * 52 + @as(u8, c.suit) * 13 + c.rank;
}

pub fn rankOf(i: u8) u8 {
    return i % 52 % 13;
}

pub fn suitOf(i: u8) u8 {
    return i % 52 / 13;
}

pub fn isRed(suit: u8) bool {
    return suit < 2; // H, D
}

/// A card's run neighbors on one side (successors or predecessors).
pub const RunNbrs = struct { pure: u8, rb: [2]u8 };

fn build(comptime step: comptime_int) [N]RunNbrs {
    var t: [N]RunNbrs = undefined;
    for (0..N) |i| {
        const r: u8 = @intCast(i % 13);
        const s: u8 = @intCast(i / 13);
        const nr = (r + step) % 13;
        const opp: [2]u8 = if (s < 2) .{ 2, 3 } else .{ 0, 1 };
        t[i] = .{
            .pure = s * 13 + nr,
            .rb = .{ opp[0] * 13 + nr, opp[1] * 13 + nr },
        };
    }
    return t;
}

pub const succ = build(1);
pub const pred = build(12); // rank-1 == rank+12 mod 13

// ---------- tests (native: ops/check_solver) ----------

test "graph shape: 3 successors each, pred inverts succ, colors correct" {
    for (0..N) |i| {
        const c: u8 = @intCast(i);
        // pure: same suit, rank+1, and pred undoes it
        try std.testing.expectEqual(suitOf(c), suitOf(succ[i].pure));
        try std.testing.expectEqual((rankOf(c) + 1) % 13, rankOf(succ[i].pure));
        try std.testing.expectEqual(c, pred[succ[i].pure].pure);
        // rb: rank+1, opposite color, distinct suits, and pred contains c
        for (succ[i].rb) |nb| {
            try std.testing.expectEqual((rankOf(c) + 1) % 13, rankOf(nb));
            try std.testing.expect(isRed(suitOf(c)) != isRed(suitOf(nb)));
            try std.testing.expect(pred[nb].rb[0] == c or pred[nb].rb[1] == c);
        }
        try std.testing.expect(succ[i].rb[0] != succ[i].rb[1]);
    }
}

test "the wrap: KH's pure successor is AH" {
    const kh = cardIndex(.{ .rank = 12, .suit = 0, .deck = 0 });
    const ah = cardIndex(.{ .rank = 0, .suit = 0, .deck = 0 });
    try std.testing.expectEqual(ah, succ[kh].pure);
}

test "rankOf/suitOf are copy-blind across the two decks" {
    for (0..N) |i| {
        const c: u8 = @intCast(i);
        try std.testing.expectEqual(rankOf(c), rankOf(c + 52));
        try std.testing.expectEqual(suitOf(c), suitOf(c + 52));
    }
    const th1 = cardIndex(.{ .rank = 9, .suit = 0, .deck = 1 });
    try std.testing.expectEqual(@as(u8, 9 + 52), th1);
}
