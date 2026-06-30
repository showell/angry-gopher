//! cat — the cat that crosses the road in front of the rider. Two parts, both mirroring the TS:
//!
//!   * CHOREOGRAPHY (cat_motion.ts): a three-phase crossing clocked in RIDER FRAMES (steps), a pure
//!     function of the rider's along-gap to the cat and his speed — ENTERS (walk in to the lane centre),
//!     FROZEN (stop dead, head swivels to face us), ESCAPES (one explosive leap clear of the road). It
//!     replays cleanly under pause/reverse because it reads only the clock.
//!
//!   * DRAWING: a FLIPBOOK of the 7 named-pose stills baked into cat_frames.zig (the seam is polygon-only,
//!     so the procedural cat_anatomy drawing is pre-baked — see ops/bake_cat). Each step selects ONE still
//!     (no interpolation); this module places it as a billboard at the cat's depth, scales it by the
//!     projected height, slides it laterally (the across travel) and hops it (the leap lift).
//!
//! DELIBERATELY NOT PORTED YET (TS has them; flagged, not forgotten): the focal pull-in as the cat crosses
//! (catFocus — the deferred view-only focus-narrowing) and the accel gate that makes the rider hold off
//! while a cat is in danger (segmentCatDanger). The cat crosses; the camera + rider ignore it for now.

const std = @import("std");
const camera = @import("camera.zig");
const geom = @import("geom.zig");
const paint = @import("paint.zig");
const frames = @import("cat_frames.zig");

// ---- crossing choreography, in rider frames (cat_motion.ts) ----
const ENTERS_ROAD_STEPS: f32 = 10;
const FROZEN_STEPS: f32 = 24;
const ESCAPES_STEPS: f32 = 4; // coil → airborne (×2) → land → collapse
const CROSS_FRAMES: f32 = ENTERS_ROAD_STEPS + FROZEN_STEPS + ESCAPES_STEPS;
const LEAP_HEIGHT: f32 = 0.18; // peak hop, in cat-heights
const ROAD_BUFFER: f32 = 3; // metres of clear road kept between rider and cat
const STRIDE_STEPS: f32 = 5; // target rider steps per leg cycle

// the rider's FOCUS tightens as a cat crosses (the focal pull-in). It ramps UP over the crossing clock,
// PEAKS at FOCUS_PEAK (an exaggerated 1.5×+ a normal full pull-in) at the landing, then eases back over
// FOCUS_RAMP_DOWN frames. View-only — folded into the camera focal by camera.camFocal. Mirrors catFocus.
const FOCUS_PEAK: f32 = 1.8;
const FOCUS_RAMP_DOWN: f32 = 83; // frames after the landing to ease focus back to none

// ---- placement / size (cat_motion.ts) ----
pub const CAT_HEIGHT: f32 = 1.7; // metres, ground to ear tips
pub const CAT_ALONG: f32 = 105; // desired spot down the road; rounded up to just past a tree
const CAT_ROAD_GAP: f32 = 1.5; // clearance beyond the roadside tree line
const CAT_BEYOND_TREE: f32 = 2; // sits this far past the rounding tree
const CAT_HEAD_X: f32 = -0.48; // head-centre x in the unit frame (cat_anatomy HEAD.cx)
const LAND_HIND_REACH: f32 = 0.70 * CAT_HEIGHT; // hind paw's reach in the landing pose
const GRASS_TOEHOLD: f32 = 0.3; // how far past the left edge the hind paw settles

// a cat in its segment's frame: it crosses from start_across (right of the road) to end_across (clear, on
// the left), pausing frozen at mid_across (head on the lane centre). + across = right of centre.
pub const Cat = struct {
    along: f32,
    start_across: f32,
    mid_across: f32,
    end_across: f32,
    height: f32,
};

// the cat's whole state this frame: which still to draw, its lateral offset, and the leap hop.
pub const State = struct { pose_idx: usize, across: f32, lift: f32 };

fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @max(lo, @min(hi, x));
}
fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// crossing progress 0..1 from the rider's along-gap to the cat (m) and his speed (m/press). The gap is
// measured to a point ROAD_BUFFER short of the cat, so the cat is clear with road still to spare. Mirrors
// crossT — pure function of the clock, so it freezes on pause and scrubs on reverse.
fn crossT(gap: f32, v: f32) f32 {
    const e = gap - ROAD_BUFFER;
    if (e <= 0) return 1; // within the buffer — fully across already
    if (v <= 1e-6) return 0; // stopped: the frame-clock isn't ticking
    return clamp(1 - e / (CROSS_FRAMES * v), 0, 1);
}

// gait phase over a walk phase of `phase_len` steps at local progress p: a whole number of leg cycles, so
// the legs start and end at rest. Mirrors gait().
fn gait(p: f32, phase_len: f32) f32 {
    const cycles = @max(1.0, @round(phase_len / STRIDE_STEPS));
    return p * cycles * 2.0 * std.math.pi;
}

// Map the crossing clock onto a step 0..CROSS_FRAMES and split it into the three phases, returning which
// still to flip to + the lateral offset + the hop. Mirrors catPose, but the continuous gait/leap shapes
// collapse to discrete stills (the flipbook): the walk SNAPS between rest and a single mid-stride still
// (on the lifted half of the gait), and the leap picks coil/flight/land/collapse by its progress — exactly
// the discrete-stills the TS leap already used (leapPoseFor).
pub fn state(c: Cat, gap_along: f32, v: f32) State {
    const step = crossT(gap_along, v) * CROSS_FRAMES;
    const freeze_at = ENTERS_ROAD_STEPS;
    const escape_at = ENTERS_ROAD_STEPS + FROZEN_STEPS;

    if (step <= freeze_at) { // ENTERS: walk in to the lane centre
        const p = if (freeze_at > 0) step / freeze_at else 1;
        const striding = @sin(gait(p, freeze_at)) > 0; // lifted half of the gait → the mid-stride still
        return .{
            .pose_idx = if (striding) frames.STRIDE else frames.REST,
            .across = lerp(c.start_across, c.mid_across, p),
            .lift = 0,
        };
    }
    if (step <= escape_at) { // FROZEN: stand dead still, facing us
        return .{ .pose_idx = frames.FROZEN, .across = c.mid_across, .lift = 0 };
    }
    // ESCAPES: the leap, by whole escape-steps. k<1 coil (planted); k in [1,3) airborne (two frames); k>=3
    // on the ground at the far side (land then collapse). leapT carries the exact phase to the still pick.
    const k = @min(step - escape_at, ESCAPES_STEPS);
    const leap_t = k / ESCAPES_STEPS;
    const pose_idx = leapPoseFor(leap_t);
    if (k < 1) return .{ .pose_idx = pose_idx, .across = c.mid_across, .lift = 0 }; // COIL
    if (k < 3) { // AIRBORNE (two frames)
        const b = (k - 1) / 2; // 0 at launch … 1 at touchdown
        return .{
            .pose_idx = pose_idx,
            .across = lerp(c.mid_across, c.end_across, std.math.pow(f32, b, 0.7)), // front-loaded
            .lift = LEAP_HEIGHT * 4 * b * (1 - b), // low parabola: 0 → peak → 0
        };
    }
    return .{ .pose_idx = pose_idx, .across = c.end_across, .lift = 0 }; // LAND + COLLAPSE
}

// the leap still for this escape phase, by the same thresholds as cat_anatomy's leapPoseFor.
fn leapPoseFor(t: f32) usize {
    if (t < 0.20) return frames.COIL;
    if (t < 0.70) return frames.FLIGHT;
    if (t < 0.95) return frames.LAND;
    return frames.COLLAPSE;
}

// Is the cat still ahead (beyond the buffer) AND inside the crossing window — i.e. crossing in front of us
// right now? Mirrors catInDanger; read by the rider's accel gate (it holds the throttle while this holds).
pub fn inDanger(gap_along: f32, v: f32) bool {
    const e = gap_along - ROAD_BUFFER;
    return e > 0 and e <= CROSS_FRAMES * v;
}

fn smoothstep(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

// the rider's attention on this crossing cat (0 = none … FOCUS_PEAK at the landing), for the focal pull-in.
// `gap_along` is the rider's road-along gap to the cat. Ramps UP on the same clock as the crossing, then
// eases DOWN over FOCUS_RAMP_DOWN frames once he's level with the landing point. Mirrors catFocusOne.
pub fn focus(gap_along: f32, v: f32) f32 {
    if (v <= 1e-6) return 0;
    const e = gap_along - ROAD_BUFFER; // to the landing point: >0 approaching, <=0 past it
    if (e > 0) return smoothstep(crossT(gap_along, v)) * FOCUS_PEAK; // ramp UP with the crossing
    return (1.0 - smoothstep(@min(-e / v / FOCUS_RAMP_DOWN, 1.0))) * FOCUS_PEAK; // ramp DOWN past it
}

// Build the segment's cat: a cat waiting beside the road on the RIGHT, just past the herd, that crosses to
// the LEFT as the rider nears. `tree_along` is the nearest right-side tree at/after CAT_ALONG (the caller
// reads the segment's actual trees — they aren't evenly spaced). Mirrors segmentCats.
pub fn make(lane_half: f32, tree_offset: f32, tree_along: f32) Cat {
    const tree_x = lane_half + tree_offset;
    return .{
        .along = tree_along + CAT_BEYOND_TREE,
        .start_across = tree_x + CAT_ROAD_GAP, // waiting spot, right of the road
        .mid_across = -CAT_HEAD_X * CAT_HEIGHT, // anchor offset that puts the head centre on the lane
        .end_across = -(lane_half + GRASS_TOEHOLD) - LAND_HIND_REACH, // hind paw barely onto the left grass
        .height = CAT_HEIGHT,
    };
}

// ---- drawing: the flipbook still as a billboard ----

// draw the cat at rider-relative (right, forward), `height` m tall, flipping to the selected still. Each
// baked unit-frame polygon (x toward the tail, y up from the feet at the origin, standing height 1) maps
// to screen: scaled by the projected height, hung off the feet anchor, hopped by the leap `lift`. The cat
// faces LEFT (the escape direction), so no horizontal flip. A billboard at one depth — no per-vertex
// near-clip (the caller only collects it when it's in front).
pub fn draw(right: f32, forward: f32, height: f32, pose_idx: usize, lift: f32, cam_focal: f32) void {
    const base = camera.project(.{ .right = right, .forward = forward, .height = 0 }, cam_focal);
    const top = camera.project(.{ .right = right, .forward = forward, .height = height }, cam_focal);
    const h = base.y - top.y;
    if (h < 1.0) return; // too small to detail (the renderer's size cull is the real cutoff)

    var screen: [256]camera.ScreenPt = undefined;
    for (frames.POSES[pose_idx].polys) |poly| {
        if (poly.pts.len > screen.len) continue;
        for (poly.pts, 0..) |p, i| {
            screen[i] = .{ .x = base.x + p.x * h, .y = base.y - (p.y + lift) * h };
        }
        paint.pushPoly(poly.color, screen[0..poly.pts.len]);
    }
}
