//! card — the card vocabulary for the zig Lyn Rummy solver, plus the
//! ASCII notation the fixtures speak ("7H", "TC'" for the second-deck
//! copy). Rank is cyclic: 0..12 = A,2,…,9,T,J,Q,K and the K→A→2 wrap is
//! just (rank+1)%13. Suits: H,D red; C,S black.
//!
//! `Counts` is the solver-facing view — per (suit, rank) multiplicity,
//! no deck labels. No meld ever distinguishes the two copies of a
//! (rank, suit): a run can't repeat a value and a set can't repeat a
//! suit, so the copies can never legally share a stack. Deck identity
//! stays at the edges (fixtures, UI, wire); the solver works on counts.

const std = @import("std");

pub const RANK_CHARS: [13]u8 = "A23456789TJQK".*;
pub const SUIT_CHARS: [4]u8 = "HDCS".*;

pub const Card = struct {
    rank: u4, // 0..12 = A..K
    suit: u2, // 0=H 1=D 2=C 3=S
    deck: u1, // 0 = plain, 1 = the ' copy
};

pub const Error = error{ BadCard, TooManyCards, TooManyCopies };

pub fn parseCard(tok: []const u8) Error!Card {
    if (tok.len < 2 or tok.len > 3) return error.BadCard;
    const rank = std.mem.indexOfScalar(u8, &RANK_CHARS, tok[0]) orelse return error.BadCard;
    const suit = std.mem.indexOfScalar(u8, &SUIT_CHARS, tok[1]) orelse return error.BadCard;
    if (tok.len == 3 and tok[2] != '\'') return error.BadCard;
    return .{
        .rank = @intCast(rank),
        .suit = @intCast(suit),
        .deck = @intFromBool(tok.len == 3),
    };
}

pub fn formatCard(c: Card, buf: *[3]u8) []const u8 {
    buf[0] = RANK_CHARS[c.rank];
    buf[1] = SUIT_CHARS[c.suit];
    buf[2] = '\'';
    return buf[0 .. 2 + @as(usize, c.deck)];
}

pub const MAX_CARDS = 104;

/// parseBoard reads a whole board line: whitespace-separated card tokens,
/// with `|` accepted (and ignored) as a stack separator — solvability
/// depends only on the multiset, so the stacking is dressing here.
pub fn parseBoard(line: []const u8, buf: *[MAX_CARDS]Card) Error![]const Card {
    var it = std.mem.tokenizeAny(u8, line, " \t|");
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n == MAX_CARDS) return error.TooManyCards;
        buf[n] = try parseCard(tok);
        n += 1;
    }
    return buf[0..n];
}

pub const Counts = [4][13]u8;

pub fn buildCounts(cards: []const Card) Error!Counts {
    var counts = std.mem.zeroes(Counts);
    for (cards) |c| {
        if (counts[c.suit][c.rank] == 2) return error.TooManyCopies;
        counts[c.suit][c.rank] += 1;
    }
    return counts;
}

// ---------- tests (native: ops/check_solver) ----------

test "all 104 cards round-trip through the notation" {
    for (0..2) |deck| {
        for (0..4) |suit| {
            for (0..13) |rank| {
                const c: Card = .{
                    .rank = @intCast(rank),
                    .suit = @intCast(suit),
                    .deck = @intCast(deck),
                };
                var buf: [3]u8 = undefined;
                try std.testing.expectEqual(c, try parseCard(formatCard(c, &buf)));
            }
        }
    }
}

test "junk tokens fail loud" {
    for ([_][]const u8{ "", "7", "1H", "7X", "H7", "7H`", "7HH'", "7h" }) |tok| {
        try std.testing.expectError(error.BadCard, parseCard(tok));
    }
}

test "board lines: stacks are dressing, the multiset is the content" {
    var buf: [MAX_CARDS]Card = undefined;
    const cards = try parseBoard("3H 4H 5H | 9C TC' JC", &buf);
    try std.testing.expectEqual(@as(usize, 6), cards.len);
    const counts = try buildCounts(cards);
    try std.testing.expectEqual(@as(u8, 1), counts[0][2]); // 3H
    try std.testing.expectEqual(@as(u8, 1), counts[2][9]); // TC (either copy)
    try std.testing.expectEqual(@as(u8, 0), counts[1][2]); // no 3D
}

test "a third copy of the same (rank, suit) is rejected" {
    var buf: [MAX_CARDS]Card = undefined;
    const cards = try parseBoard("7H 7H' 7H", &buf);
    try std.testing.expectError(error.TooManyCopies, buildCounts(cards));
}
