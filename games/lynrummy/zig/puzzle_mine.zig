//! puzzle_mine — mine a gallery puzzle from real self-play (Steve's
//! ask, 2026-07-24): play one game (sim.zig), take the hardest SOLVED
//! probe — the arrangement whose cover cost the solver the most
//! steps — and print it in the curated-catalog DSL, ready to append
//! to conformance/curated_sim_puzzles.dsl (curation stays a human
//! act). The dump goes to stderr, like cut_dump.
//!
//! No flags; the tunable is the constant below (generate_game.ts
//! precedent). Pick specimen seeds with a sweep over sim.playGame
//! comparing stats.hard_steps.

const std = @import("std");
const card = @import("card.zig");
const arrangement = @import("arrangement.zig");
const solver = @import("solver.zig");
const moves = @import("moves.zig");
const sim = @import("sim.zig");

const SEED: u32 = 441;

// Row-wrap layout inside the 800px board, same constants as
// ts/publish_cut_game.ts.
const LEFT_START = 20;
const TOP_START = 20;
const GAP_X = 24;
const ROW_HEIGHT = 60;
const RIGHT_EDGE = 780;
const CARD_WIDTH = 27;
const CARD_PITCH = 33;

fn glyphToken(c: card.Card, buf: *[8]u8) []const u8 {
    const glyphs = [4][]const u8{ "♥", "♦", "♣", "♠" }; // zig suit order H,D,C,S
    buf[0] = card.RANK_CHARS[c.rank];
    const g = glyphs[c.suit];
    @memcpy(buf[1 .. 1 + g.len], g);
    var n = 1 + g.len;
    if (c.deck == 1) {
        buf[n] = '\'';
        n += 1;
    }
    return buf[0..n];
}

pub fn main() !void {
    const p = std.debug.print;
    const res = try sim.playGame(SEED);
    if (res.stats.hard_steps == 0) {
        p("seed {d}: no solved probe recorded; nothing to mine\n", .{SEED});
        return error.NoHardMove;
    }
    var arr = res.stats.hard_arr;
    // Cover dressing is copy-blind; a published board needs DISTINCT
    // physical copies (two bare 5♣ would confuse the UI and the
    // player). First occurrence wears no mark, the twin wears one.
    var seen = [_]bool{false} ** 52;
    for (arr.cards[0..arr.nCards()]) |*c| {
        const base = @as(usize, c.suit) * 13 + c.rank;
        c.deck = @intFromBool(seen[base]);
        seen[base] = true;
    }
    // Re-solve + distill for the provenance comment: the miner never
    // emits a puzzle it can't prove solvable right now.
    const sol = (try solver.solveArrangement(&arr)).solved;
    var plan: moves.Plan = undefined;
    try moves.distill(&arr, &sol.next, arr.n_stacks, &plan);
    p("# Mined {d}-card board from self-play seed {d}, turn {d}: the\n", .{ arr.nCards(), SEED, res.stats.hard_turn });
    p("# hardest solved move of the game ({d} solver steps; the\n", .{res.stats.hard_steps});
    p("# reference consolidation runs {d} verb moves).\n", .{plan.n});
    p("puzzle sim_s{d}t{d}\n", .{ SEED, res.stats.hard_turn });
    var left: u32 = LEFT_START;
    var top: u32 = TOP_START;
    for (0..arr.n_stacks) |si| {
        const cs = arr.stackCards(si);
        const width: u32 = CARD_WIDTH + (@as(u32, @intCast(cs.len)) - 1) * CARD_PITCH;
        if (left + width > RIGHT_EDGE and left > LEFT_START) {
            left = LEFT_START;
            top += ROW_HEIGHT;
        }
        p("  at ({d},{d}):", .{ left, top });
        for (cs) |c| {
            var buf: [8]u8 = undefined;
            p(" {s}", .{glyphToken(c, &buf)});
        }
        p("\n", .{});
        left += width + GAP_X;
    }
}
