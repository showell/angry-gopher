//! puzzle_gate — every gallery puzzle must be SOLVABLE, with a
//! definitive verdict (Steve's ask, 2026-07-24). The six curated
//! catalogs are the single source of truth (the same files
//! zig-server/build.zig embeds for the live gallery); this file
//! lives one directory up from the solver so @embedFile can reach
//! them — module roots can't cross "..".
//!
//! The gate solves each puzzle FROM ITS OWN STACKS via
//! solveArrangement — exactly what the Hint button experiences on the
//! puzzle's start state, warm ordering and all. (The first sim-mined
//! puzzle made the distinction load-bearing: its multiset is
//! cold-UNKNOWN at the 1M give-up line, but its arrangement solves
//! warm in 623k steps — hard is the point.) A stack that isn't a
//! legal meld chain enters as loose singletons, which is what an
//! arbitrary pile physically is. The verdict must be .solved: a
//! futile gallery puzzle is a broken product, and an unknown one is
//! a puzzle the hint button can't stand behind — both fail loud with
//! the puzzle's name. Catalog counts are pinned so a parser drift
//! can never pass vacuously; adding or removing puzzles updates the
//! pin consciously.
//!
//! Gate: ops/check_solver (explicit line — the zig/*.zig glob can't
//! see this file).

const std = @import("std");
const card = @import("zig/card.zig");
const graph = @import("zig/graph.zig");
const arrangement = @import("zig/arrangement.zig");
const solver = @import("zig/solver.zig");

const CATALOGS = [_]struct { name: []const u8, text: []const u8, count: usize }{
    .{ .name = "1line", .text = @embedFile("conformance/curated_1line_puzzles.dsl"), .count = 10 },
    .{ .name = "2line", .text = @embedFile("conformance/curated_2line_puzzles.dsl"), .count = 10 },
    .{ .name = "3line", .text = @embedFile("conformance/curated_3line_puzzles.dsl"), .count = 10 },
    .{ .name = "4line", .text = @embedFile("conformance/curated_4line_puzzles.dsl"), .count = 21 },
    .{ .name = "5line", .text = @embedFile("conformance/curated_5line_puzzles.dsl"), .count = 11 },
    .{ .name = "6line", .text = @embedFile("conformance/curated_6line_puzzles.dsl"), .count = 15 },
    .{ .name = "sim", .text = @embedFile("conformance/curated_sim_puzzles.dsl"), .count = 3 },
};

const Puzzle = struct {
    name: []const u8,
    arr: arrangement.Arrangement,
};

/// Parse one catalog: "puzzle <name>" headers, then "at (x,y): 2♥ …"
/// board lines with unicode suits and ' deck marks — each at-line is
/// one physical stack. Anything unparseable fails loud — a catalog
/// typo must never read as a smaller gallery.
fn parseCatalog(text: []const u8, out: []Puzzle) !usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "puzzle ")) {
            out[n] = .{ .name = line["puzzle ".len..], .arr = undefined };
            out[n].arr.n_stacks = 0;
            out[n].arr.start[0] = 0;
            n += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "at (")) {
            if (n == 0) return error.BoardLineBeforePuzzle;
            const colon = std.mem.indexOf(u8, line, "): ") orelse return error.BadBoardLine;
            var stack: [card.MAX_CARDS]card.Card = undefined;
            var sn: usize = 0;
            var toks = std.mem.tokenizeScalar(u8, line[colon + 3 ..], ' ');
            while (toks.next()) |tok| {
                if (sn == card.MAX_CARDS) return error.TooManyCards;
                stack[sn] = try parseGlyphCard(tok);
                sn += 1;
            }
            if (sn == 0) return error.BadBoardLine;
            addStack(&out[n - 1].arr, stack[0..sn]);
            continue;
        }
        return error.UnknownLine;
    }
    return n;
}

/// A legal meld chain enters as one stack (its edges warm the solve,
/// as in the live UI); anything else enters as loose singletons —
/// which is what an arbitrary pile physically is.
fn addStack(arr: *arrangement.Arrangement, cs: []const card.Card) void {
    if (stackLegal(cs)) {
        appendStack(arr, cs);
    } else {
        for (cs) |c| appendStack(arr, &.{c});
    }
}

fn appendStack(arr: *arrangement.Arrangement, cs: []const card.Card) void {
    var at = arr.start[arr.n_stacks];
    for (cs) |c| {
        arr.cards[at] = c;
        at += 1;
    }
    arr.n_stacks += 1;
    arr.start[arr.n_stacks] = at;
}

fn stackLegal(cs: []const card.Card) bool {
    if (cs.len == 1) return true;
    const flavor = graph.edgeFlavor(graph.cardIndex(cs[0]), graph.cardIndex(cs[1])) orelse return false;
    var suits: u8 = @as(u8, 1) << cs[0].suit;
    var ranks: u16 = @as(u16, 1) << cs[0].rank;
    for (cs[1..], 1..) |c, i| {
        const f = graph.edgeFlavor(graph.cardIndex(cs[i - 1]), graph.cardIndex(c)) orelse return false;
        if (f != flavor) return false;
        if (f == .set) {
            const b = @as(u8, 1) << c.suit;
            if (suits & b != 0) return false;
            suits |= b;
        } else {
            const b = @as(u16, 1) << c.rank;
            if (ranks & b != 0) return false;
            ranks |= b;
        }
    }
    return true;
}

/// "T♦'" → Card. Rank letter, 3-byte suit glyph, optional deck mark.
fn parseGlyphCard(tok: []const u8) !card.Card {
    if (tok.len < 4) return error.BadCard;
    const suits = [4]struct { glyph: []const u8, letter: u8 }{
        .{ .glyph = "♥", .letter = 'H' },
        .{ .glyph = "♦", .letter = 'D' },
        .{ .glyph = "♣", .letter = 'C' },
        .{ .glyph = "♠", .letter = 'S' },
    };
    for (suits) |s| {
        if (std.mem.eql(u8, tok[1..4], s.glyph)) {
            var ascii: [3]u8 = .{ tok[0], s.letter, '\'' };
            const len: usize = if (tok.len == 5 and tok[4] == '\'') 3 else if (tok.len == 4) 2 else return error.BadCard;
            return card.parseCard(ascii[0..len]);
        }
    }
    return error.BadCard;
}

test "every gallery puzzle is solvable, definitively" {
    var buf: [64]Puzzle = undefined;
    for (CATALOGS) |cat| {
        const n = try parseCatalog(cat.text, &buf);
        try std.testing.expectEqual(cat.count, n);
        for (buf[0..n]) |p| {
            const out = try solver.solveArrangement(&p.arr);
            if (out != .solved) {
                std.debug.print("UNSOLVABLE gallery puzzle ({s}, verdict {s}): {s}\n", .{
                    cat.name, @tagName(out), p.name,
                });
                return error.GalleryPuzzleNotSolvable;
            }
        }
    }
}
