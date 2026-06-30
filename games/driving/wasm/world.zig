//! world — the road network as data: a chain of straight segments joined by turns.
//! Each segment carries its length, width, tree rows, and its EXIT turn (angle +
//! direction + the segment it leads to); buildWorld accumulates each segment's
//! heading relative to north. A subset of the real route (world.ts) — enough to
//! show left/right turns of varying sharpness and the gold/red tree schemes — wired
//! into a LOOP so the screensaver runs forever. No rider, no projection, no drawing.

const std = @import("std");
const cat = @import("cat.zig");

pub const Color = u32; // 0xRRGGBB, opaque

pub const Scheme = enum { all_green, yellow_green, red_green };

pub const Tree = struct { along: f32, across: f32, color: Color, height: f32 };

// a roadside animal: an emoji billboard at (along, across-from-centre).
pub const Critter = struct { along: f32, across: f32, codepoint: u32, height: f32, face_right: bool };

pub const MAX_TREES = 96; // fixed-spacing trees scale with length; the long seg7 needs the headroom
pub const MAX_COWS = 16; // a bull + 14 cows/calves
pub const MAX_SEGMENTS = 16;

pub const Segment = struct {
    length: f32,
    width: f32,
    trees: [MAX_TREES]Tree,
    n_trees: usize,
    cows: [MAX_COWS]Critter,
    n_cows: usize,
    // exit turn: angle (rad) + right? + the index of the segment it leads to.
    exit_angle: f32,
    exit_right: bool,
    exit_to: usize,
    commit_along: f32, // the `along` at which the rider commits to the exit turn
    north_heading: f32, // accumulated heading vs north (seg 0 = 0)
    has_mid_tower: bool, // a long segment stands its own tower halfway down
    has_cat: bool, // a cat waits beside this segment and crosses as the rider nears
    cat: cat.Cat, // its placement + crossing endpoints (valid only when has_cat)
};

pub const World = struct {
    segments: [MAX_SEGMENTS]Segment,
    n_segments: usize,
};

// ---- tree palette + dimensions, mirrored from tree.ts ----
const CONIFER_GREEN: Color = 0x1c5a22;
const CONIFER_GOLD: Color = 0xcf9a18;
const CONIFER_RED: Color = 0xb23a2a;
const SMALL_HEIGHT: f32 = 4.5;
const BIG_SCALE: f32 = 1.3;
const TREE_SPACING: f32 = 30.0; // metres between trees — FIXED (count scales with length), diverging from TS's fixed count, so density (and the speed illusion) is uniform across segments
const TREE_ROAD_OFFSET: f32 = 1.5;
const TREE_START_INSET: f32 = 6.0;
const TREE_END_INSET: f32 = 85.0;
const LANE_WIDTH: f32 = 4.0;
const DEG: f32 = std.math.pi / 180.0;
const MID_TOWER_MIN_LENGTH: f32 = 1000.0; // longer segments stand their own mid-tower

// ---- the cow herd (the boring CONSTANT on every segment, near the start, on the
// left): a bull leading 10 cows + 4 calves, in a deterministic jittered grid.
// Mirrors cowHerd() in farm_critter.ts. Pigs/safari creatures are NOT ported. ----
const BULL_CP: u32 = 0x1F402; // 🐂
const COW_CP: u32 = 0x1F404; // 🐄
const COW_HEIGHT: f32 = 1.4;
const CALF_HEIGHT: f32 = COW_HEIGHT / 2.0;
const BULL_HEIGHT: f32 = COW_HEIGHT * 1.15;
const HERD_ROAD_OFFSET: f32 = 10.0;
const BULL_DIST: f32 = 24.0;
const BULL_TREE_GAP: f32 = 0.5;
const HERD_GAP_BEHIND_BULL: f32 = 6.0;
const HERD_COL_SPACING: f32 = 6.0;
const HERD_ROW_STAGGER: f32 = 2.0;
const HERD_ROW_DEPTH: f32 = 5.0;
const HERD_JITTER_ALONG: f32 = 1.5;
const HERD_JITTER_ACROSS: f32 = 1.2;

fn fillCows(seg: *Segment) void {
    const hw = LANE_WIDTH / 2.0;
    const edge = hw + HERD_ROAD_OFFSET;
    const tree_x = hw + TREE_ROAD_OFFSET; // the roadside tree line the bull lines up with
    seg.n_cows = 0;
    seg.cows[0] = .{ .along = BULL_DIST, .across = -(tree_x + BULL_HEIGHT / 2.0 + BULL_TREE_GAP), .codepoint = BULL_CP, .height = BULL_HEIGHT, .face_right = false };
    seg.n_cows = 1;
    var i: usize = 0;
    while (i < 14) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const col: f32 = @floatFromInt(i / 3);
        const row: f32 = @floatFromInt(i % 3);
        const along = BULL_DIST + HERD_GAP_BEHIND_BULL + col * HERD_COL_SPACING + (row - 1.0) * HERD_ROW_STAGGER + HERD_JITTER_ALONG * @sin(fi * 2.7);
        const across = -(edge + row * HERD_ROW_DEPTH + HERD_JITTER_ACROSS * @cos(fi * 1.9));
        const calf = (i % 4) == 1; // i = 1,5,9,13 → 4 calves at half size
        seg.cows[seg.n_cows] = .{ .along = along, .across = across, .codepoint = COW_CP, .height = if (calf) CALF_HEIGHT else COW_HEIGHT, .face_right = true };
        seg.n_cows += 1;
    }
}

fn accentColor(scheme: Scheme) Color {
    return switch (scheme) {
        .yellow_green => CONIFER_GOLD,
        .red_green => CONIFER_RED,
        .all_green => CONIFER_GREEN,
    };
}

// fillTrees: conifers every TREE_SPACING metres from the start inset to the end-clear
// zone — a FIXED spacing, so count scales with length and density is uniform across
// segments (no per-segment speed illusion). Even index = green + 1.3× tall, odd = the
// scheme's accent. Red trees 2× everything; gold 3× and set ~4× further off the road.
fn fillTrees(seg: *Segment, scheme: Scheme) void {
    const lane_half = LANE_WIDTH / 2.0;
    const end_along = seg.length - TREE_END_INSET;
    const tree_line = lane_half + TREE_ROAD_OFFSET;
    seg.n_trees = 0;
    var k: usize = 0;
    var along = TREE_START_INSET;
    while (along <= end_along and seg.n_trees + 2 <= MAX_TREES) : (k += 1) {
        const even = (k % 2) == 0;
        const color: Color = if (even) CONIFER_GREEN else accentColor(scheme);
        var height: f32 = if (even) SMALL_HEIGHT * BIG_SCALE else SMALL_HEIGHT;
        var x = tree_line;
        if (color == CONIFER_RED) height *= 2.0;
        if (color == CONIFER_GOLD) {
            height *= 3.0;
            x = lane_half + 4.0 * TREE_ROAD_OFFSET;
        }
        seg.trees[seg.n_trees] = .{ .along = along, .across = -x, .color = color, .height = height };
        seg.n_trees += 1;
        seg.trees[seg.n_trees] = .{ .along = along, .across = x, .color = color, .height = height };
        seg.n_trees += 1;
        along += TREE_SPACING;
    }
}

// the authored route: length, scheme, and the exit turn (signed degrees, + = right)
// onto the next segment. The last entry loops back to segment 0.
const Cfg = struct { length: f32, scheme: Scheme, turn_deg: f32, cat: bool = false };
const route = [_]Cfg{
    .{ .length = 500, .scheme = .all_green, .turn_deg = 50, .cat = true }, // seg1 → 50° right, has a crossing cat
    .{ .length = 320, .scheme = .all_green, .turn_deg = -70 }, // seg2 → 70° left
    .{ .length = 400, .scheme = .all_green, .turn_deg = 20 }, // seg3 → 20° right
    .{ .length = 300, .scheme = .yellow_green, .turn_deg = 20 }, // seg4 (gold) → 20° right
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70 }, // seg5 → 70° left
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70 }, // seg6 → 70° left
    .{ .length = 1200, .scheme = .red_green, .turn_deg = 80, .cat = true }, // seg7 (red, long) → 80° right, loops to seg1
};

// the smallest right-side tree `along` at or after `desired` — the cat tucks just past it, so a tree
// stands between the rider and the cat. Trees aren't evenly spaced, so read the segment's actual rows.
// Mirrors nextTreeAlong in cat_motion.ts.
fn nextTreeAlong(seg: *const Segment, desired: f32) f32 {
    var best: f32 = std.math.inf(f32);
    var i: usize = 0;
    while (i < seg.n_trees) : (i += 1) {
        const t = seg.trees[i];
        if (t.across > 0 and t.along >= desired and t.along < best) best = t.along;
    }
    return if (std.math.isInf(best)) desired else best;
}

/// buildWorld authors the looping route, builds each segment's tree rows, and
/// accumulates the headings.
pub fn buildWorld() World {
    var w = World{ .segments = undefined, .n_segments = route.len };
    for (route, 0..) |c, i| {
        var seg = &w.segments[i];
        seg.length = c.length;
        seg.width = LANE_WIDTH;
        seg.exit_angle = @abs(c.turn_deg) * DEG;
        seg.exit_right = c.turn_deg >= 0;
        seg.exit_to = (i + 1) % route.len; // loop back at the end
        // the rider crosses the next segment's inner-edge extension hw/tan(theta)
        // before the segment's end and commits to the turn (road_segment.ts).
        seg.commit_along = c.length - (LANE_WIDTH / 2.0) / @tan(seg.exit_angle);
        seg.north_heading = 0;
        seg.has_mid_tower = c.length > MID_TOWER_MIN_LENGTH;
        fillTrees(seg, c.scheme);
        fillCows(seg);
        seg.has_cat = c.cat;
        seg.cat = if (c.cat) cat.make(LANE_WIDTH / 2.0, TREE_ROAD_OFFSET, nextTreeAlong(seg, cat.CAT_ALONG)) else undefined;
    }
    // accumulate north headings along the route (seg 0 = 0); stop before wrapping so
    // the loop's seg 0 keeps heading 0 (a clean cut, not an ever-growing spiral).
    var i: usize = 0;
    while (i + 1 < w.n_segments) : (i += 1) {
        const sgn: f32 = if (w.segments[i].exit_right) 1.0 else -1.0;
        w.segments[i + 1].north_heading = w.segments[i].north_heading + sgn * w.segments[i].exit_angle;
    }
    return w;
}
