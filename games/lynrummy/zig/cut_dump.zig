//! cut_dump — play one self-play game (sim.zig) and print its CUT
//! STATE: the full game state at the start of the first turn where a
//! solver probe gave up. The dump goes to stderr (zig 0.16 file IO
//! wants a threaded Io instance; ops/publish_lynrummy_cut captures
//! the stream instead), and games/lynrummy/ts/publish_cut_game.ts
//! turns it into a playable session.
//!
//! No flags; the tunable is the constant below (generate_game.ts
//! precedent). Pick specimen seeds with a sweep over sim.playGame —
//! seeds whose stats.probe_unknowns > 0 have a cut to dump.

const std = @import("std");
const card = @import("card.zig");
const sim = @import("sim.zig");

const SEED: u32 = 240;

pub fn main() !void {
    const p = std.debug.print;
    const res = try sim.playGame(SEED);
    const cut = res.cut orelse {
        p("seed {d}: no solver give-up in this game; nothing to dump\n", .{SEED});
        return error.NoCut;
    };
    var buf: [512]u8 = undefined;
    p("# zig sim cut state: first solver give-up of seed {d}\n", .{SEED});
    p("seed: {d}\nturn: {d}\nactive: {d}\n", .{ SEED, cut.turn, cut.active });
    for (0..cut.board.n_stacks) |si| {
        p("stack: {s}\n", .{sim.handLine(cut.board.stackCards(si), &buf)});
    }
    p("hand0: {s}\n", .{sim.handLine(cut.hands[0][0..cut.hand_len[0]], &buf)});
    p("hand1: {s}\n", .{sim.handLine(cut.hands[1][0..cut.hand_len[1]], &buf)});
    p("deck: {s}\n", .{sim.handLine(cut.deck[0..cut.deck_len], &buf)});
}
