//! gaze — the DISTRACTED RIDER: as he nears a segment with pigs his curiosity wins, so he slows to take
//! them in and turns his GAZE toward one designated pig, tracking it as he creeps past, then swings his eyes
//! back to the road. Three coupled effects, all keyed off how far that pig still is ahead:
//!
//!   * a VIEW-ONLY head-turn (gaze_yaw, rad) — an extra camera yaw the renderer adds to the rider's heading
//!     (safari folds it into the view). Swivels gently toward the pig, tracks it, then drifts back to the road.
//!   * a BRAKE (pigGazeBrake) + a never-re-accelerate hold (gawkEngaged) — rider folds these into its forward
//!     decision so he eases to a slow gawk speed and holds it for the rest of the segment.
//!   * a FOCUS (gazeFocus, 0..1) — the camera narrows as he gawks (folded into camera.camFocal), rising with
//!     the head-turn and decaying slowly once his eyes are home.
//!
//! Run AFTER the bike has moved each frame (rider.getNextRiderState calls nextRiderGaze last). It aims at a
//! REAL rendered pig — world.gazePig is the single source of where that pig sits — so the head-turn and the
//! billboard can never drift apart. Faithful port of rider_gaze.ts.

const std = @import("std");
const rider = @import("rider.zig");
const world = @import("world.zig");

const DEG: f32 = std.math.pi / 180.0;
const GAZE_LOOK_DIST: f32 = 150; // notices the pigs (and starts slowing) when the pig is this far ahead (m)
pub const GAZE_RELEASE_ANGLE: f32 = 35 * DEG; // gaze peaks here; once the pig swings this far off his heading he looks back
const GAZE_SWIVEL_RATE: f32 = 4 * DEG; // most his head turns TOWARD the pig in one frame (a gentle swivel)
const GAZE_RETURN_RATE: f32 = 0.2 * DEG; // the slow, unhurried drift BACK to the road for the bulk of the return
const GAZE_RETURN_EASE: f32 = 0.05; // near straight the return step shrinks to this fraction of the remaining angle (decelerates in)
const GAZE_RETURN_SNAP: f32 = 0.02 * DEG; // below this remaining angle, snap the last sliver to 0 (keeps the focus trigger exact)
const FOCUS_DECAY: f32 = 0.0012; // once fully straightened, the focus progress bleeds off this much per frame
pub const PIG_GAZE_SPEED: f32 = 0.20; // the slow gawk speed he eases to, then HOLDS for the rest of the segment (m/press)
const PIG_GAZE_SETTLE_DIST: f32 = 25; // finishes slowing this far before the pig, then creeps past at the gawk speed
const EYES_ON_ROAD_YAW: f32 = 6 * DEG; // pointed more than this off the lane = mid-corner, eyes snap back to the road

fn smoothstep(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

// the narrowing of his focus (0 = normal … 1 = fully narrowed) — folded into the camera focal. state.focus
// is a LINEAR progress; smoothstep it so the narrow/re-widen eases gently in and out. Mirrors gazeFocus.
pub fn gazeFocus(focus: f32) f32 {
    return smoothstep(focus);
}

// How far the designated pig is still AHEAD, but only while he's in the looking window: a distraction leg,
// eyes not committed to a corner, the pig within GAZE_LOOK_DIST ahead, and not yet swung past
// GAZE_RELEASE_ANGLE off his heading. null = no pig interest (gaze + brake fall back to driving normally).
fn pigAhead(state: rider.RiderState, seg: world.Segment) ?f32 {
    if (!seg.pigs_distract) return null;
    if (@abs(state.yaw) > EYES_ON_ROAD_YAW) return null; // mid straighten-out: eyes on the road
    const pig = world.gazePig(seg.length, seg.width / 2.0);
    const dist = pig.along - state.along;
    if (dist > GAZE_LOOK_DIST) return null; // not noticed yet
    const bearing = std.math.atan2(pig.across - state.across, dist) - state.yaw;
    return if (@abs(bearing) >= GAZE_RELEASE_ANGLE) null else dist; // swung beside him → back to the road
}

// Where he WANTS to look this frame: the bearing to the designated pig (relative to his heading), or 0 when
// he has no pig interest. A bearing, not a fixed angle, so his gaze tracks the pig as he creeps past it.
fn desiredGaze(state: rider.RiderState, seg: world.Segment) f32 {
    if (pigAhead(state, seg) == null) return 0;
    const pig = world.gazePig(seg.length, seg.width / 2.0);
    return std.math.atan2(pig.across - state.across, pig.along - state.along) - state.yaw;
}

// THE GAZE STEP — run after the bike has moved: swivel his head one frame toward where he wants to look.
// Toward the pig is a gentle fixed-rate swivel; the drift back to the road lingers, then decelerates into
// straight (snapping the last sliver to 0). Also drives FOCUS (a linear progress; gazeFocus smoothsteps it):
// while his head is turned it rises with the turn and HOLDS its peak, easing out only once fully straightened.
pub fn nextRiderGaze(state: rider.RiderState, w: *const world.World) rider.RiderState {
    const want = desiredGaze(state, w.segments[state.segment]);
    var gaze_yaw: f32 = undefined;
    if (want != 0) {
        const delta = want - state.gaze_yaw;
        gaze_yaw = state.gaze_yaw + @max(-GAZE_SWIVEL_RATE, @min(GAZE_SWIVEL_RATE, delta));
    } else if (@abs(state.gaze_yaw) <= GAZE_RETURN_SNAP) {
        gaze_yaw = 0;
    } else {
        const step = @min(GAZE_RETURN_RATE, @abs(state.gaze_yaw) * GAZE_RETURN_EASE);
        gaze_yaw = state.gaze_yaw - std.math.sign(state.gaze_yaw) * step;
    }
    const focus = if (gaze_yaw == 0)
        @max(0.0, state.focus - FOCUS_DECAY) // straightened → ease the focus back slowly
    else
        @max(state.focus, @min(@abs(gaze_yaw) / GAZE_RELEASE_ANGLE, 1.0)); // turned → rise with the turn, hold the peak
    var out = state;
    out.gaze_yaw = gaze_yaw;
    out.focus = focus;
    return out;
}

// Once he's NOTICED the pigs (the designated pig within GAZE_LOOK_DIST ahead) he's committed to the slow
// gawk for the REST of the segment — sticky + purely positional (the crossing resets him next segment).
// Distinct from pigAhead (the HEAD-turn, which also ends once the pig is beside him); this is the MOTION
// hold, so it ignores the eyes-on-road gate and persists into the turn. Mirrors gawkEngaged.
pub fn gawkEngaged(state: rider.RiderState, seg: world.Segment) bool {
    if (!seg.pigs_distract) return false;
    return state.along >= world.gazePig(seg.length, seg.width / 2.0).along - GAZE_LOOK_DIST;
}

// THE GAWK BRAKE — rider folds this into its min-of-brakes. null until he's noticed the pigs; from then on he
// eases toward PIG_GAZE_SPEED (the same kinematic v² = vEnd² + 2·a·d the corner brake uses), timed to settle a
// little before the pig so he creeps PAST it at the gawk speed, then holds (0). Mirrors pigGazeBrake.
pub fn pigGazeBrake(state: rider.RiderState, seg: world.Segment) ?f32 {
    if (!gawkEngaged(state, seg)) return null; // hasn't noticed the pigs yet → drive normally
    if (state.v <= PIG_GAZE_SPEED) return 0; // at the gawk speed → hold it (never re-accelerates)
    const d = world.gazePig(seg.length, seg.width / 2.0).along - state.along - PIG_GAZE_SETTLE_DIST;
    return (PIG_GAZE_SPEED * PIG_GAZE_SPEED - state.v * state.v) / (2.0 * @max(d, 1.0));
}
