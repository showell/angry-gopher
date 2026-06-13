// rider_gaze.ts — the "distracted rider": as he approaches a segment that has pigs, his CURIOSITY gets
// the better of him — he slows down to take them in and turns his GAZE toward one particular pig, tracking
// it as he creeps past, then swings his eyes back to the road. Two coupled effects, both keyed off how far
// the pig still is ahead of him:
//   • a VIEW-ONLY head-turn (gazeYaw, radians) — never touches the path or the physics; the renderer reads
//     it as an extra camera yaw (view.ts / main.ts). It SWIVELS gently toward the pig (a couple frames to
//     turn his head, not a jerk), tracks it, then once the pig is beside him swings back to the road faster
//     (he's done looking) — he has real interest, not a tic.
//   • a brake (pigGazeBrake) — rider.ts folds this into its forward decision so he eases down to a slow
//     gawking speed to actually see them. That's the one place the gaze reaches into the motion.
// The gaze is its OWN step, run AFTER the bike has moved each frame (the caller runs bike-then-gaze; see
// getNextRiderState). It aims at a REAL rendered pig — farm_critter.gazePig is the single source of where
// that pig sits — so the head-turn and the billboard can never drift apart.

import type { RiderState } from './rider.ts';
import type { RoadSegment } from './road_segment.ts';
import type { World } from './world.ts';
import { gazePig } from './farm_critter.ts';

// --- the tunables (head-swivel rates, the gawk speed, when he notices / loses interest) ---
const GAZE_LOOK_DIST = 150;                       // he notices the pigs (and starts slowing) when the pig is this far ahead (m) — bigger = he begins decelerating earlier (and starts his subtle far-off head-turn earlier)
const GAZE_RELEASE_ANGLE = 45 * Math.PI / 180;    // the gaze PEAKS here — once the pig has swung this far off his heading (~beside him, just down the road) he loses it and looks back
const GAZE_SWIVEL_RATE = 4 * Math.PI / 180;       // most his head turns TOWARD the pig in one frame (rad) — the gentle "couple frames to turn" knob
const GAZE_RETURN_RATE = 1.1 * Math.PI / 180;     // most his head turns BACK to the road in one frame — a slow, unhurried drift back to the road once he releases
const PIG_GAZE_SPEED = 0.15;                      // the slow speed he eases down to so he can savour the pigs (m/press) — he holds it until his eyes are back on the road
const PIG_GAZE_SETTLE_DIST = 25;                  // he finishes slowing to the gawk speed this far before the pig, then CREEPS the rest of the way at it (so he's at the gawk speed well before he looks away)
const EYES_ON_ROAD_YAW = 6 * Math.PI / 180;       // pointed more than this off the lane = mid-corner, eyes snap back to the road

// the current head-turn of the distracted gaze (radians, an offset from his heading) — read by the renderer
// as an extra camera yaw. Just the stored field now; the swivel that produces it lives in nextRiderGaze.
export function gazeAngle(state: RiderState): number {
  return state.gazeYaw;
}

// How far the designated pig is still AHEAD of the rider, but only while he's in the looking window: pigs on
// this leg, eyes not already committed to a corner, the pig within GAZE_LOOK_DIST metres ahead, and not yet
// swung past GAZE_RELEASE_ANGLE off his heading (once it's beside him he loses interest). null = no pig
// interest right now (so both the gaze and the brake fall back to "drive normally"). The single gate both
// effects share, so the head-turn and the slow-down begin and end together.
function pigAhead(state: RiderState, seg: RoadSegment): number | null {
  if (!seg.pigs) return null;
  if (Math.abs(state.yaw) > EYES_ON_ROAD_YAW) return null;   // mid straighten-out: eyes on the road, no gawking
  const pig = gazePig(seg.length, seg.width / 2);
  const dist = pig.along - state.along;
  if (dist > GAZE_LOOK_DIST) return null;                    // not noticed yet
  const bearing = Math.atan2(pig.across - state.across, dist) - state.yaw;
  return Math.abs(bearing) >= GAZE_RELEASE_ANGLE ? null : dist;   // swung beside him -> back to the road
}

// Where he WANTS to be looking this frame: the bearing to the designated pig (relative to his heading, so the
// renderer can add it straight onto state.yaw), or 0 (eyes front) when he has no pig interest. Bearing, not a
// fixed angle, so as he creeps past the pig his gaze tracks it — swinging further to the side the closer he gets.
function desiredGaze(state: RiderState, seg: RoadSegment): number {
  if (pigAhead(state, seg) === null) return 0;
  const pig = gazePig(seg.length, seg.width / 2);
  return Math.atan2(pig.across - state.across, pig.along - state.along) - state.yaw;
}

// THE GAZE STEP — run AFTER the bike has moved this frame: swivel his head one frame toward where he wants to
// look (desiredGaze), capped so it's a turn of the head, not a snap. The cap is ASYMMETRIC: gentle toward the
// pig (GAZE_SWIVEL_RATE — a couple frames to turn), faster back to the road (GAZE_RETURN_RATE — eyes return
// quickly once he releases, want = 0).
export function nextRiderGaze(state: RiderState, world: World): RiderState {
  const want = desiredGaze(state, world.segments[state.segment]);
  const rate = want === 0 ? GAZE_RETURN_RATE : GAZE_SWIVEL_RATE;
  const delta = Math.max(-rate, Math.min(rate, want - state.gazeYaw));
  const gazeYaw = state.gazeYaw + delta;
  return gazeYaw === state.gazeYaw ? state : { ...state, gazeYaw };
}

// THE GAWK BRAKE — rider.ts asks this for the deceleration the pig-distraction wants this frame, and folds it
// into its min-of-brakes forward decision. He's "distracted" while he's looking OR while his eyes are still
// swinging back (gazeYaw not yet 0). Distracted and still too fast: ease down toward PIG_GAZE_SPEED (the same
// kinematic v^2 = vEnd^2 + 2*a*d the corner brake uses), timed to SETTLE a little before the pig so he creeps
// PAST it at the gawk speed rather than only touching it. Once at the gawk speed: hold (0) — and he keeps
// holding through the eye-return, so he never re-accelerates until his eyes are back on the road. null = eyes
// front, no constraint, drive normally.
export function pigGazeBrake(state: RiderState, seg: RoadSegment): number | null {
  const dist = pigAhead(state, seg);
  if (dist === null && state.gazeYaw === 0) return null;       // eyes front -> drive normally
  if (state.v <= PIG_GAZE_SPEED) return 0;                     // at the gawk speed -> hold it (no re-accelerating)
  const d = dist === null ? PIG_GAZE_SETTLE_DIST : dist - PIG_GAZE_SETTLE_DIST;   // distance over which to bleed down to the gawk speed
  return (PIG_GAZE_SPEED * PIG_GAZE_SPEED - state.v * state.v) / (2 * Math.max(d, 1));
}
