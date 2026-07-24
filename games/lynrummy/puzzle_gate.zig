//! puzzle_gate — every gallery puzzle must be SOLVABLE, with a
//! definitive verdict (Steve's ask, 2026-07-24). The six curated
//! catalogs are the single source of truth (the same files
//! zig-server/build.zig embeds for the live gallery); this file
//! lives one directory up from the solver so @embedFile can reach
//! them — module roots can't cross "..".
//!
//! Solvability depends only on each puzzle's card multiset, so the
//! gate lowers every board to bits and demands solve() == .solved:
//! a `futile` gallery puzzle is a broken product, and an `unknown`
//! one is a puzzle the hint button can't stand behind — both fail
//! loud with the puzzle's name. Catalog counts are pinned so a
//! parser drift can never pass vacuously; adding or removing
//! puzzles updates the pin consciously.
//!
//! Gate: ops/check_solver (explicit line — the zig/*.zig glob can't
//! see this file).

const std = @import("std");
const card = @import("zig/card.zig");
const solver = @import("zig/solver.zig");

const CATALOGS = [_]struct { name: []const u8, text: []const u8, count: usize }{
    .{ .name = "1line", .text = @embedFile("conformance/curated_1line_puzzles.dsl"), .count = 10 },
    .{ .name = "2line", .text = @embedFile("conformance/curated_2line_puzzles.dsl"), .count = 10 },
    .{ .name = "3line", .text = @embedFile("conformance/curated_3line_puzzles.dsl"), .count = 10 },
    .{ .name = "4line", .text = @embedFile("conformance/curated_4line_puzzles.dsl"), .count = 21 },
    .{ .name = "5line", .text = @embedFile("conformance/curated_5line_puzzles.dsl"), .count = 11 },
    .{ .name = "6line", .text = @embedFile("conformance/curated_6line_puzzles.dsl"), .count = 15 },
};

const Puzzle = struct {
    name: []const u8,
    cards: [card.MAX_CARDS]card.Card,
    n: usize,
};

/// Parse one catalog: "puzzle <name>" headers, then "at (x,y): 2♥ …"
/// board lines with unicode suits and ' deck marks. Anything
/// unparseable fails loud — a catalog typo must never read as a
/// smaller gallery.
fn parseCatalog(text: []const u8, out: []Puzzle) !usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "puzzle ")) {
            out[n] = .{ .name = line["puzzle ".len..], .cards = undefined, .n = 0 };
            n += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "at (")) {
            if (n == 0) return error.BoardLineBeforePuzzle;
            const colon = std.mem.indexOf(u8, line, "): ") orelse return error.BadBoardLine;
            var toks = std.mem.tokenizeScalar(u8, line[colon + 3 ..], ' ');
            while (toks.next()) |tok| {
                const p = &out[n - 1];
                if (p.n == card.MAX_CARDS) return error.TooManyCards;
                p.cards[p.n] = try parseGlyphCard(tok);
                p.n += 1;
            }
            continue;
        }
        return error.UnknownLine;
    }
    return n;
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
            const bits = try solver.boardBits(p.cards[0..p.n]);
            const out = solver.solve(bits);
            if (out != .solved) {
                std.debug.print("UNSOLVABLE gallery puzzle ({s}, verdict {s}): {s}\n", .{
                    cat.name, @tagName(out), p.name,
                });
                return error.GalleryPuzzleNotSolvable;
            }
        }
    }
}
