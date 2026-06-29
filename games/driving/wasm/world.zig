//! world — the road network as data: a chain of straight segments joined by turns.
//! Each segment carries its length, width, tree rows, and its EXIT turn (angle +
//! direction + the segment it leads to); buildWorld accumulates each segment's
//! heading relative to north. A subset of the real route (world.ts) — enough to
//! show left/right turns of varying sharpness and the gold/red tree schemes — wired
//! into a LOOP so the screensaver runs forever. No rider, no projection, no drawing.

const std = @import("std");

pub const Color = u32; // 0xRRGGBB, opaque

pub const Scheme = enum { all_green, yellow_green, red_green };

pub const Tree = struct { along: f32, across: f32, color: Color, height: f32 };

pub const MAX_TREES = 96; // fixed-spacing trees scale with length; the long seg7 needs the headroom
pub const MAX_SEGMENTS = 16;

pub const Segment = struct {
    length: f32,
    width: f32,
    trees: [MAX_TREES]Tree,
    n_trees: usize,
    // exit turn: angle (rad) + right? + the index of the segment it leads to.
    exit_angle: f32,
    exit_right: bool,
    exit_to: usize,
    north_heading: f32, // accumulated heading vs north (seg 0 = 0)
    has_mid_tower: bool, // a long segment stands its own tower halfway down
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
const Cfg = struct { length: f32, scheme: Scheme, turn_deg: f32 };
const route = [_]Cfg{
    .{ .length = 500, .scheme = .all_green, .turn_deg = 50 }, // seg1 → 50° right
    .{ .length = 320, .scheme = .all_green, .turn_deg = -70 }, // seg2 → 70° left
    .{ .length = 400, .scheme = .all_green, .turn_deg = 20 }, // seg3 → 20° right
    .{ .length = 300, .scheme = .yellow_green, .turn_deg = 20 }, // seg4 (gold) → 20° right
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70 }, // seg5 → 70° left
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70 }, // seg6 → 70° left
    .{ .length = 1200, .scheme = .red_green, .turn_deg = 80 }, // seg7 (red, long) → 80° right, loops to seg1
};

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
        seg.north_heading = 0;
        seg.has_mid_tower = c.length > MID_TOWER_MIN_LENGTH;
        fillTrees(seg, c.scheme);
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
