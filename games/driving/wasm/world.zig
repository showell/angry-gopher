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

// the big animal parked at a segment's EXIT corner (safari_critter.zig owns the species + placement).
// ELEPHANT is the default; the rest are the rare departures. `pond` is a hand-drawn scene (pond.zig — water
// + bank + three ducks, not an emoji pair); `none` = no corner creature (the terminus).
pub const Creature = enum { none, elephant, giraffe, zebra, rhino, pond };

pub const Tree = struct { along: f32, across: f32, color: Color, height: f32 };

// a roadside animal: an emoji billboard at (along, across-from-centre).
pub const Critter = struct { along: f32, across: f32, codepoint: u32, height: f32, face_right: bool };

pub const MAX_TREES = 96; // fixed-spacing trees scale with length; the long seg7 needs the headroom
pub const MAX_COWS = 16; // a bull + 14 cows/calves
pub const MAX_PIGS = 49; // the 7×7 big distraction herd (small pig rows fit too)
pub const MAX_SEGMENTS = 20; // the full TS route is 19 segments

pub const Segment = struct {
    length: f32,
    width: f32,
    trees: [MAX_TREES]Tree,
    n_trees: usize,
    cows: [MAX_COWS]Critter,
    n_cows: usize,
    pigs: [MAX_PIGS]Critter, // this segment's roadside pigs (big distraction herd or small row)
    n_pigs: usize,
    pigs_distract: bool, // a DISTRACTION leg (the first 2 pig appearances): big herd + the rider gawks/slows
    // exit turn: angle (rad) + right? + the index of the segment it leads to.
    exit_angle: f32,
    exit_right: bool,
    exit_to: usize,
    commit_along: f32, // the `along` at which the rider commits to the exit turn
    north_heading: f32, // accumulated heading vs north (seg 0 = 0)
    has_mid_tower: bool, // a long segment stands its own tower halfway down
    has_cat: bool, // a cat waits beside this segment and crosses as the rider nears
    cat: cat.Cat, // its placement + crossing endpoints (valid only when has_cat)
    terminates: bool, // the FINISH segment: no turn leads out of it; the rider arrives and stops
    exit_creature: Creature, // the big animal parked at this segment's exit corner
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

// `bull` is authored per-segment in the route table (like .cat/.pigs/.creature) so the whole schedule of
// surprises reads in one place — the shaded Fluent-Color bull is the herd's standout, held back for a debut.
fn fillCows(seg: *Segment, bull: bool) void {
    const hw = LANE_WIDTH / 2.0;
    const edge = hw + HERD_ROAD_OFFSET;
    const tree_x = hw + TREE_ROAD_OFFSET; // the roadside tree line the bull lines up with
    seg.n_cows = 0;
    if (bull) {
        seg.cows[0] = .{ .along = BULL_DIST, .across = -(tree_x + BULL_HEIGHT / 2.0 + BULL_TREE_GAP), .codepoint = BULL_CP, .height = BULL_HEIGHT, .face_right = false };
        seg.n_cows = 1;
    }
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

// ---- the pig DISTRACTION herd (farm_critter.ts): a deep 7×7 staggered block near the segment's end on
// the RIGHT. The rider gawks at one designated pig (gazePig) — slowing + turning his head — as he passes.
// Only the big herd is ported (the wasm flags only distraction legs); the small non-distraction pig row
// isn't. Deterministic sine/cosine jitter, no randomness. ----
const PIG_CP: u32 = 0x1F416; // 🐖
const PIG_HEIGHT: f32 = 1.1;
const PIG_NOVELTY_COUNT: usize = 2; // only the first this-many pig appearances DISTRACT (the novelty wears off)
const PIG_DIST_BEFORE_END: f32 = 60.0; // pigs gather this far before the next intersection
const GAZE_PIG_ALONG_OFFSET: f32 = 2.0; // the designated pig sits just past the cluster front
const BIG_HERD_COLS: usize = 7;
const BIG_HERD_ROWS: usize = 7;
const PIG_COL_SPACING: f32 = 4.0;
const PIG_ROW_DEPTH: f32 = 6.0; // across-spacing AND the per-row along-shear (45° slanted sides)
const PIG_JITTER_ALONG: f32 = 1.2;
const PIG_JITTER_ACROSS: f32 = 1.0;
const PIG_HERD_FIRST_COL: f32 = -6.0; // along-offset of each row's near pig

// gazePig: the ONE front-row pig the distracted rider fixes on, so the head-turn always aims at a rendered
// pig. across = lane edge + the herd's road offset. Mirrors gazePig in farm_critter.ts.
pub fn gazePig(length: f32, lane_half: f32) Critter {
    return .{
        .along = length - PIG_DIST_BEFORE_END + GAZE_PIG_ALONG_OFFSET,
        .across = lane_half + HERD_ROAD_OFFSET,
        .codepoint = PIG_CP,
        .height = PIG_HEIGHT,
        .face_right = false,
    };
}

const PIG_BACK_ROW_OFFSET: f32 = 6.0; // the small row's back rank sits this much further from the road

// the DISTRACTION herd: a deep 7×7 staggered block (the first couple of pig appearances). Mirrors pigHerd.
fn fillPigHerd(seg: *Segment) void {
    const edge = LANE_WIDTH / 2.0 + HERD_ROAD_OFFSET;
    const base = seg.length - PIG_DIST_BEFORE_END;
    var r: usize = 0;
    while (r < BIG_HERD_ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < BIG_HERD_COLS) : (c += 1) {
            const i: f32 = @floatFromInt(r * BIG_HERD_COLS + c);
            const fr: f32 = @floatFromInt(r);
            const fc: f32 = @floatFromInt(c);
            const along = base + PIG_HERD_FIRST_COL + fc * PIG_COL_SPACING + fr * PIG_ROW_DEPTH + PIG_JITTER_ALONG * @sin(i * 2.3);
            const across = edge + fr * PIG_ROW_DEPTH + PIG_JITTER_ACROSS * @cos(i * 1.7);
            seg.pigs[seg.n_pigs] = .{ .along = along, .across = across, .codepoint = PIG_CP, .height = PIG_HEIGHT, .face_right = false };
            seg.n_pigs += 1;
        }
    }
}

// the small non-distraction row: a front rank of 4 at the road edge + a back rank of 6 further off. The
// rider doesn't gawk at these. Mirrors pigRow in farm_critter.ts.
fn fillPigRow(seg: *Segment) void {
    const edge = LANE_WIDTH / 2.0 + HERD_ROAD_OFFSET;
    const base = seg.length - PIG_DIST_BEFORE_END;
    const front = [_]f32{ -6, -2, 2, 6 };
    const back = [_]f32{ -10, -6, -2, 2, 6, 10 };
    for (front) |d| {
        seg.pigs[seg.n_pigs] = .{ .along = base + d, .across = edge, .codepoint = PIG_CP, .height = PIG_HEIGHT, .face_right = false };
        seg.n_pigs += 1;
    }
    for (back) |d| {
        seg.pigs[seg.n_pigs] = .{ .along = base + d, .across = edge + PIG_BACK_ROW_OFFSET, .codepoint = PIG_CP, .height = PIG_HEIGHT, .face_right = false };
        seg.n_pigs += 1;
    }
}

// place this segment's pigs: the big distraction herd (the rider gawks) or the small scenery row.
fn fillPigs(seg: *Segment, distract: bool) void {
    seg.n_pigs = 0;
    if (distract) fillPigHerd(seg) else fillPigRow(seg);
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

// turn_deg is the SIGNED exit turn onto the next segment (+ right / − left); the LAST entry has no turn —
// it's the TERMINUS (the finish line). Mirrors the segmentConfigs + turns tables in world.ts.
const Cfg = struct { length: f32, scheme: Scheme, turn_deg: f32 = 0, cat: bool = false, pigs: bool = false, bull: bool = false, terminates: bool = false, creature: Creature = .elephant };

// The full TS route (world.ts): 19 segments. The baseline is deliberately boring (ALL_GREEN, a cow herd)
// so the rare departures surprise; novelty is front-loaded (seg2 cat, seg3 pigs, seg4 gold), the long
// sunset stretches (seg7/seg10) stay calm, then a NEW/boring/boring rhythm from seg13. The CAT debuts on
// seg2 and recurs on seg13/seg19; PIGS debut alone on seg3, then a near-constant motif from seg11 (gone on
// seg16 as a surprise). RED trees clue the notable segments. seg19 is the terminus — the photo-finish line.
// Corner CREATURES: a GIRAFFE debut (seg5), RHINOs at the sunset stretch (seg7), the duck POND (seg13, a
// right turn — was the crocodile lagoon), a ZEBRA (seg16); ELEPHANT is the unmarked default elsewhere.
const route = [_]Cfg{
    .{ .length = 500, .scheme = .all_green, .turn_deg = 50 }, // seg1: plain opener (no bull yet)
    .{ .length = 320, .scheme = .all_green, .turn_deg = -70, .cat = true }, // seg2: the CAT crossing debuts
    .{ .length = 400, .scheme = .all_green, .turn_deg = 20, .pigs = true }, // seg3: pigs first appear (distraction)
    .{ .length = 300, .scheme = .yellow_green, .turn_deg = 20 }, // seg4: gold trees (one-off); still no bull (let the pigs breathe)
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70, .bull = true, .creature = .giraffe }, // seg5: first giraffe + the BULL debuts (staple from here)
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70, .bull = true }, // seg6
    .{ .length = 1200, .scheme = .red_green, .turn_deg = 80, .bull = true, .creature = .rhino }, // seg7: rhinos at the sunset-stretch corner
    .{ .length = 300, .scheme = .all_green, .turn_deg = 15, .bull = true }, // seg8
    .{ .length = 300, .scheme = .all_green, .turn_deg = -70, .bull = true }, // seg9
    .{ .length = 800, .scheme = .all_green, .turn_deg = 15, .bull = true }, // seg10: second sun-ward stretch
    .{ .length = 300, .scheme = .all_green, .turn_deg = 15, .pigs = true, .bull = true }, // seg11: pigs return (2nd distraction)
    .{ .length = 300, .scheme = .all_green, .turn_deg = 15, .pigs = true, .bull = true }, // seg12
    .{ .length = 300, .scheme = .red_green, .turn_deg = 15, .cat = true, .pigs = true, .bull = true, .creature = .pond }, // seg13: the duck pond (right turn) + cat; red-tree clue
    .{ .length = 400, .scheme = .all_green, .turn_deg = -50, .pigs = true, .bull = true }, // seg14
    .{ .length = 300, .scheme = .all_green, .turn_deg = 50, .pigs = true, .bull = true }, // seg15
    .{ .length = 300, .scheme = .red_green, .turn_deg = -50, .bull = true, .creature = .zebra }, // seg16: zebra; SURPRISE — pigs gone
    .{ .length = 300, .scheme = .all_green, .turn_deg = 50, .pigs = true, .bull = true }, // seg17: pigs back
    .{ .length = 300, .scheme = .all_green, .turn_deg = -50, .pigs = true, .bull = true }, // seg18
    .{ .length = 300, .scheme = .red_green, .cat = true, .pigs = true, .bull = true, .terminates = true }, // seg19: red + cat finale, the terminus
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

/// courseLength: the sum of the segment lengths (intersection arcs ignored as negligible) — the distance
/// the truck's chase schedule lerps its lead down over. Mirrors courseLength in truck.ts.
pub fn courseLength(w: *const World) f32 {
    var l: f32 = 0;
    var i: usize = 0;
    while (i < w.n_segments) : (i += 1) l += w.segments[i].length;
    return l;
}

/// routeDistance: how far along the course a point (segment + along) sits — the lengths of all earlier
/// segments in route order plus the along. The truck anchors its schedule to the rider's routeDistance.
/// Mirrors routeDistance in rider.ts (position-based, not arc-length). The segments ARE in route order
/// (seg i exits to i+1), so the prefix is just the sum of lengths before `seg`.
pub fn routeDistance(w: *const World, seg: usize, along: f32) f32 {
    var d: f32 = 0;
    var i: usize = 0;
    while (i < seg) : (i += 1) d += w.segments[i].length;
    return d + along;
}

/// buildWorld authors the finite route, builds each segment's tree rows, and accumulates the headings. The
/// last segment TERMINATES (no turn out) — the rider arrives and stops there (the photo-finish line).
pub fn buildWorld() World {
    var w = World{ .segments = undefined, .n_segments = route.len };
    var pig_appearances: usize = 0; // the first PIG_NOVELTY_COUNT pig legs are the DISTRACTION herds
    for (route, 0..) |c, i| {
        var seg = &w.segments[i];
        seg.length = c.length;
        seg.width = LANE_WIDTH;
        seg.terminates = c.terminates;
        seg.exit_creature = if (c.terminates) .none else c.creature; // the terminus has no exit corner
        seg.exit_angle = @abs(c.turn_deg) * DEG;
        seg.exit_right = c.turn_deg >= 0;
        seg.exit_to = if (c.terminates) i else i + 1; // the terminus has no next
        // the rider crosses the next segment's inner-edge extension hw/tan(theta) before the segment's end
        // and commits to the turn (road_segment.ts); the terminus has no turn, so he commits at the end.
        seg.commit_along = if (c.terminates) c.length else c.length - (LANE_WIDTH / 2.0) / @tan(seg.exit_angle);
        seg.north_heading = 0;
        seg.has_mid_tower = c.length > MID_TOWER_MIN_LENGTH;
        fillTrees(seg, c.scheme);
        fillCows(seg, c.bull);
        seg.has_cat = c.cat;
        seg.cat = if (c.cat) cat.make(LANE_WIDTH / 2.0, TREE_ROAD_OFFSET, nextTreeAlong(seg, cat.CAT_ALONG)) else undefined;
        seg.n_pigs = 0;
        seg.pigs_distract = false;
        if (c.pigs) {
            pig_appearances += 1;
            seg.pigs_distract = pig_appearances <= PIG_NOVELTY_COUNT; // only the first 2 pig legs distract
            fillPigs(seg, seg.pigs_distract);
        }
    }
    // accumulate north headings along the route (seg 0 = 0), each segment's from the previous one's exit
    // turn. The route is finite (no wrap), so this just runs seg0 → the terminus.
    var i: usize = 0;
    while (i + 1 < w.n_segments) : (i += 1) {
        const sgn: f32 = if (w.segments[i].exit_right) 1.0 else -1.0;
        w.segments[i + 1].north_heading = w.segments[i].north_heading + sgn * w.segments[i].exit_angle;
    }
    return w;
}
