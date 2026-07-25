//! calib — the human-vs-solver grading ritual for mined puzzles
//! (78/79/80 precedent): Steve's replayed final arrangement vs the
//! solver's own line on the same board, both graded by reportKept and
//! distilled to verbs. The two wire constants below are pasted from
//! ts/tools/replay_puzzle.ts output (no flags; current occupants =
//! puzzle 80, sim_s441t5, 2026-07-25: Steve 37/45 in 12 verbs, algo
//! 33/45 in 22).
//! Build/run: zig build-exe -O ReleaseFast -femit-bin=/tmp/calib
//! calib.zig && /tmp/calib

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");
const arrangement = @import("arrangement.zig");
const solver = @import("solver.zig");
const moves = @import("moves.zig");

const ORIG = "6H>7H>8H>9H 7D=7C=7S 8D>9C>TD>JC>QH 9D>TC>JD QD>KS>AD>2S>3D>4S KD=KH=KS'=KC 2C>3H>4C>5H>6S 3C>4H>5C QC>KD'>AC>2D AS>2H>3C' 3S>4D>5S QD'=QH'=QS AC'=AH=AS' 4C'=4D'=4H' 5S'>6D>7C'>8D' 6S'>7H'>8S>9D'>TS TC'";
const FINAL = "6H>7H>8H>9H 9D>TC>JD QD>KS>AD>2S>3D>4S 3C>4H>5C AS>2H>3C' QD'=QH'=QS AC'=AH=AS' 4C'=4D'=4H' 5S'>6D>7C'>8D' 5S>6S>7S QC>KD'>AC>2D>3S>4D 2C>3H>4C>5H>6S'>7D 7C>8D>9C 7H'>8S>9D' TS=TC'=TD KD=KH=KS' JC>QH>KC";

fn slotOf(c: card.Card) u8 {
    return @as(u8, c.deck) * 52 + @as(u8, c.suit) * 13 + c.rank;
}

fn report(name: []const u8, orig: *const arrangement.Arrangement, next: *const [graph.SLOTS]u8) !void {
    const p = std.debug.print;
    const rep = arrangement.reportKept(orig, next);
    var plan: moves.Plan = undefined;
    try moves.distill(orig, next, orig.n_stacks, &plan);
    var buf: [8192]u8 = undefined;
    p("=== {s}: kept {d}/{d} edges, {d} distilled verbs ===\n{s}\n", .{
        name, rep.kept_edges, rep.total_edges, plan.n, moves.formatPlan(&plan, &buf),
    });
}

pub fn main() !void {
    const orig = try arrangement.parse(ORIG);
    const fin = try arrangement.parse(FINAL);
    var next: [graph.SLOTS]u8 = @splat(graph.NONE);
    for (0..fin.n_stacks) |si| {
        const cs = fin.stackCards(si);
        for (0..cs.len - 1) |i| next[slotOf(cs[i])] = slotOf(cs[i + 1]);
    }
    try report("STEVE", &orig, &next);
    const sol = (try solver.solveArrangement(&orig)).solved;
    std.debug.print("(solver steps this run: {d})\n", .{solver.steps_used});
    try report("ALGO", &orig, &sol.next);
}
