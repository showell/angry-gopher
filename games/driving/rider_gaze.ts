// rider_gaze.ts — the "distracted rider": as he approaches a segment that has pigs, his CURIOSITY gets
// the better of him — he slows down to take them in and turns his GAZE toward one particular pig, tracking
// it as he creeps past, then swings his eyes back to the road. Two coupled effects, both keyed off how far
// the pig still is ahead of him:
//   • a VIEW-ONLY head-turn (gazeYaw, radians) — never touches the path or the physics; the renderer reads
//     it as an extra camera yaw (view.ts / main.ts). It SWIVELS gently toward the pig (a couple frames to
//     turn his head, not a jerk), tracks it, then once the pig is beside him swings back to the road faster
//     (he's done looking) — he has real interest, not a tic.
//   • a brake (pigGazeBrake) + a never-re-accelerate hold (gawkEngaged) — rider.ts folds these into its
//     forward decision so he eases down to a slow gawking speed and then STAYS there for the rest of the
//     segment (he doesn't speed back up after the pigs; the next segment resets him). That's where the gaze
//     reaches into the motion.
//   • a FOCUS (gazeFocus, 0..1) — the camera narrows as he gawks (main.ts), rising with the head-turn and
//     decaying slowly back so the view eases out of the narrow focus well after his eyes are home.
// The gaze is its OWN step, run AFTER the bike has moved each frame (the caller runs bike-then-gaze; see
// getNextRiderState). It aims at a REAL rendered pig — farm_critter.gazePig is the single source of where
// that pig sits — so the head-turn and the billboard can never drift apart.

import type { RiderState } from './rider.ts';
import type { RoadSegment, SegId } from './road_segment.ts';
import type { World } from './world.ts';
import { gazePig } from './farm_critter.ts';

// --- the tunables (head-swivel rates, the gawk speed, when he notices / loses interest) ---
const PIG_NOVELTY_COUNT = 2;                      // he's only distracted by the pigs the first N times they appear on the route — a novelty that wears off (afterward he's seen pigs, keeps his eyes on the road)
const GAZE_LOOK_DIST = 150;                       // he notices the pigs (and starts slowing) when the pig is this far ahead (m) — bigger = he begins decelerating earlier (and starts his subtle far-off head-turn earlier)
const GAZE_RELEASE_ANGLE = 35 * Math.PI / 180;    // the gaze PEAKS here — once the pig has swung this far off his heading (~beside him, just down the road) he loses it and looks back (also the normaliser for the focus)
const GAZE_SWIVEL_RATE = 4 * Math.PI / 180;       // most his head turns TOWARD the pig in one frame (rad) — the gentle "couple frames to turn" knob
const GAZE_RETURN_RATE = 0.6 * Math.PI / 180;     // the head's BACK-to-the-road drift rate for the bulk of the return — a very slow, unhurried linger once he releases
const GAZE_RETURN_EASE = 0.15;                     // near straight the return step shrinks to this fraction of the remaining angle, so the head DECELERATES into straight (no sharp stop). Crossover ~ GAZE_RETURN_RATE/this (~4deg)
const GAZE_RETURN_SNAP = 0.02 * Math.PI / 180;    // below this remaining angle, snap the last (sub-pixel) sliver to 0 — keeps the focus's "fully straightened" trigger exact
const FOCUS_DECAY = 0.0012;                        // once his head is fully STRAIGHTENED, the focus PROGRESS bleeds off this much per frame (1 -> 0 over ~830 frames). The stored value is a linear progress; gazeFocus smoothsteps it so the actual re-widen eases gently out of the hold and settles softly (no velocity kink at either end)
const PIG_GAZE_SPEED = 0.20;                      // the slow speed he eases down to so he can savour the pigs (m/press) — then HOLDS it for the rest of the segment (never re-accelerates after the pigs)
const PIG_GAZE_SETTLE_DIST = 25;                  // he finishes slowing to the gawk speed this far before the pig, then CREEPS the rest of the way at it (so he's at the gawk speed well before he looks away)
const EYES_ON_ROAD_YAW = 6 * Math.PI / 180;       // pointed more than this off the lane = mid-corner, eyes snap back to the road

// the current head-turn of the distracted gaze (radians, an offset from his heading) — read by the renderer
// as an extra camera yaw. Just the stored field now; the swivel that produces it lives in nextRiderGaze.
export function gazeAngle(state: RiderState): number {
  return state.gazeYaw;
}

// the current narrowing of his focus (0 = normal, 1 = fully narrowed) — read by the camera (main.ts) to pull
// the focal in. The stored state.focus is a LINEAR progress; we smoothstep it here so the camera's narrow/
// re-widen eases gently in and out (zero rate of change at both ends) instead of starting/stopping abruptly.
export function gazeFocus(state: RiderState): number {
  const f = state.focus;
  return f * f * (3 - 2 * f);   // smoothstep
}

// Is THIS segment one of the first PIG_NOVELTY_COUNT pig-bearing segments on the route? Walk the route in
// order, counting pig legs; the distraction only fires while that count is still within the novelty window.
// Pure function of the world, so the rider needs no "how many pigs have I seen" counter in his state.
function pigsAreNovel(world: World, segId: SegId): boolean {
  let seen = 0;
  for (const id of world.order) {
    if (!world.segments[id].pigs) continue;
    seen++;
    if (id === segId) return seen <= PIG_NOVELTY_COUNT;
  }
  return false;   // not a pig leg at all
}

// How far the designated pig is still AHEAD of the rider, but only while he's in the looking window: a pig leg
// that's still a NOVELTY (one of the first two), eyes not already committed to a corner, the pig within
// GAZE_LOOK_DIST metres ahead, and not yet swung past GAZE_RELEASE_ANGLE off his heading (once it's beside him
// he loses interest). null = no pig interest right now (so both the gaze and the brake fall back to "drive
// normally"). The single gate both effects share, so the head-turn and the slow-down begin and end together.
function pigAhead(state: RiderState, seg: RoadSegment, world: World): number | null {
  if (!pigsAreNovel(world, seg.id)) return null;             // no pigs here, or the novelty has worn off
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
function desiredGaze(state: RiderState, seg: RoadSegment, world: World): number {
  if (pigAhead(state, seg, world) === null) return 0;
  const pig = gazePig(seg.length, seg.width / 2);
  return Math.atan2(pig.across - state.across, pig.along - state.along) - state.yaw;
}

// THE GAZE STEP — run AFTER the bike has moved this frame: swivel his head one frame toward where he wants to
// look (desiredGaze). Turning TOWARD the pig is a gentle fixed-rate swivel (GAZE_SWIVEL_RATE — a couple frames
// to turn). The drift BACK to the road (want = 0) lingers at GAZE_RETURN_RATE for the bulk, then DECELERATES as
// it nears straight (the step shrinks with the remaining angle) so the head eases into straight rather than
// stopping sharply — the last sliver snaps to 0 to keep the focus trigger exact. Also drives FOCUS (a linear
// PROGRESS; gazeFocus smoothsteps it for the camera): while his head is turned AT ALL it rises with the turn and
// HOLDS its peak; it only begins easing out once he's fully STRAIGHTENED (gazeYaw back to 0), then slowly.
export function nextRiderGaze(state: RiderState, world: World): RiderState {
  const want = desiredGaze(state, world.segments[state.segment], world);
  let gazeYaw: number;
  if (want !== 0) {
    gazeYaw = state.gazeYaw + Math.max(-GAZE_SWIVEL_RATE, Math.min(GAZE_SWIVEL_RATE, want - state.gazeYaw));
  } else if (Math.abs(state.gazeYaw) <= GAZE_RETURN_SNAP) {
    gazeYaw = 0;
  } else {
    const step = Math.min(GAZE_RETURN_RATE, Math.abs(state.gazeYaw) * GAZE_RETURN_EASE);   // constant linger, easing out near straight
    gazeYaw = state.gazeYaw - Math.sign(state.gazeYaw) * step;
  }
  const focus = gazeYaw === 0
    ? Math.max(0, state.focus - FOCUS_DECAY)                              // straightened out -> ease the focus back slowly
    : Math.max(state.focus, Math.min(Math.abs(gazeYaw) / GAZE_RELEASE_ANGLE, 1));   // head turned -> rise with the turn, hold the peak
  return gazeYaw === state.gazeYaw && focus === state.focus ? state : { ...state, gazeYaw, focus };
}

// Once he's NOTICED the pigs on a novel pig leg (the designated pig has come within GAZE_LOOK_DIST ahead), he's
// committed to the slow gawk for the REST of the segment: he eases to the gawk speed and never re-accelerates
// until he leaves the segment (the crossing resets him). Sticky and purely positional — he can't un-notice —
// so no counter in his state. Distinct from pigAhead (the HEAD-turn), which also ends once the pig is beside
// him; this is just the MOTION hold, so it ignores the eyes-on-road-in-a-corner gate and persists into the turn.
export function gawkEngaged(state: RiderState, seg: RoadSegment, world: World): boolean {
  if (!pigsAreNovel(world, seg.id)) return false;
  return state.along >= gazePig(seg.length, seg.width / 2).along - GAZE_LOOK_DIST;
}

// THE GAWK BRAKE — rider.ts folds this into its min-of-brakes forward decision. null until he's noticed the
// pigs; from then on he eases down toward PIG_GAZE_SPEED (the same kinematic v^2 = vEnd^2 + 2*a*d the corner
// brake uses), timed to SETTLE a little before the pig so he creeps PAST it at the gawk speed rather than only
// touching it, then holds (0) at the gawk speed for the rest of the segment. (rider.ts ALSO suppresses the
// corner entry-speed floor while gawkEngaged, so the corner can't snap him back up — he never re-accelerates.)
export function pigGazeBrake(state: RiderState, seg: RoadSegment, world: World): number | null {
  if (!gawkEngaged(state, seg, world)) return null;           // hasn't noticed the pigs yet -> drive normally
  if (state.v <= PIG_GAZE_SPEED) return 0;                    // at the gawk speed -> hold it (never re-accelerates)
  const d = gazePig(seg.length, seg.width / 2).along - state.along - PIG_GAZE_SETTLE_DIST;   // distance over which to bleed down
  return (PIG_GAZE_SPEED * PIG_GAZE_SPEED - state.v * state.v) / (2 * Math.max(d, 1));
}
