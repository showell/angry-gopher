//! world — the road network as data. For the first frame this is ONE straight
//! segment lined with the alternating-conifer tree rows; the segment chain, turns,
//! towers, and mountains arrive later. No rider, no projection, no drawing. Mirrors
//! segmentTrees() in tree.ts + the seg1 config in world.ts (ALL_GREEN, 500 m).

pub const Color = u32; // 0xRRGGBB, opaque (the blitter prefixes '#')

pub const Tree = struct { along: f32, across: f32, color: Color, height: f32 };

pub const MAX_TREES = 64;
pub const Segment = struct {
    length: f32,
    width: f32,
    trees: [MAX_TREES]Tree,
    n_trees: usize,
};

// tree palette + dimensions, mirrored from tree.ts (ALL_GREEN scheme for now: the
// accent is just more green, so every conifer is CONIFER_GREEN).
const CONIFER_GREEN: Color = 0x1c5a22;
const SMALL_HEIGHT: f32 = 4.5; // odd-parity conifers
const BIG_SCALE: f32 = 1.3; // even-parity conifers stand this much taller
const TREES_PER_SIDE: usize = 11;
const TREE_ROAD_OFFSET: f32 = 1.5; // a tree stands this far beyond the lane edge
const TREE_START_INSET: f32 = 6.0; // first tree, past the entry join
const TREE_END_INSET: f32 = 85.0; // last tree, short of the (future) intersection
const LANE_WIDTH: f32 = 4.0;

/// buildWorld authors the first-frame world: seg1 (a 500 m ALL_GREEN straight) with
/// its two tree rows — exactly segmentTrees(500, ALL_GREEN, 2) from tree.ts.
pub fn buildWorld() Segment {
    const length: f32 = 500.0;
    const lane_half = LANE_WIDTH / 2.0;
    var seg = Segment{ .length = length, .width = LANE_WIDTH, .trees = undefined, .n_trees = 0 };

    const start_along = TREE_START_INSET;
    const end_along = length - TREE_END_INSET;
    const spacing = (end_along - start_along) / @as(f32, @floatFromInt(TREES_PER_SIDE - 1));
    const tree_line = lane_half + TREE_ROAD_OFFSET;

    var k: usize = 0;
    while (k < TREES_PER_SIDE) : (k += 1) {
        const along = start_along + @as(f32, @floatFromInt(k)) * spacing;
        const even = (k % 2) == 0;
        const height: f32 = if (even) SMALL_HEIGHT * BIG_SCALE else SMALL_HEIGHT;
        // both rows (alternating parity drives size; ALL_GREEN keeps one colour)
        seg.trees[seg.n_trees] = .{ .along = along, .across = -tree_line, .color = CONIFER_GREEN, .height = height };
        seg.n_trees += 1;
        seg.trees[seg.n_trees] = .{ .along = along, .across = tree_line, .color = CONIFER_GREEN, .height = height };
        seg.n_trees += 1;
    }
    return seg;
}
