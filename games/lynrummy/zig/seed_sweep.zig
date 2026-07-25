//! seed_sweep — specimen scout for puzzle mining (see
//! ops/mine_lynrummy_puzzle): play a seed range through sim.playGame
//! and report each game's hardest solved probe; the max is the next
//! puzzle candidate. Edit the range constants below (no flags).
//! Build/run: zig build-exe -O ReleaseFast -femit-bin=/tmp/sweep
//! seed_sweep.zig && /tmp/sweep. Mined so far: 107, 95 (from 1..300,
//! pre-deepening), 441 (from 301..500, 2026-07-25 solver).

const std = @import("std");
const sim = @import("sim.zig");

const SEED_FIRST: u32 = 301;
const SEED_LAST: u32 = 500;

pub fn main() !void {
    const p = std.debug.print;
    var best_seed: u32 = 0;
    var best_steps: u64 = 0;
    var seed: u32 = SEED_FIRST;
    while (seed <= SEED_LAST) : (seed += 1) {
        const res = sim.playGame(seed) catch |e| {
            p("seed {d}: ERROR {s}\n", .{ seed, @errorName(e) });
            continue;
        };
        const s = res.stats;
        if (s.hard_steps == 0) {
            p("seed {d}: no sweep-graded solve\n", .{seed});
            continue;
        }
        p("seed {d}: hard_steps {d} turn {d} cards {d}\n", .{ seed, s.hard_steps, s.hard_turn, s.hard_arr.nCards() });
        if (s.hard_steps > best_steps) {
            best_steps = s.hard_steps;
            best_seed = seed;
        }
    }
    p("BEST seed {d}: {d} steps\n", .{ best_seed, best_steps });
}
