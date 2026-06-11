// rider_gaze.ts — the "distracted rider": a slow, VIEW-ONLY glance toward the roadside pigs and back as
// he cruises up to a turn, then eyes back on the road before braking. Decoupled from the bike motion
// (rider.ts): the gaze is its OWN step, run AFTER the bike has moved each frame. It's a pure function of
// where he now is on the segment (progress) and whether the segment has pigs — never of the path or the
// physics. The renderer reads gazeAngle as a camera yaw (main.ts/view.ts).

import type { RiderState } from './rider.ts';
import type { World } from './world.ts';

// the glance: ramp the head-turn up to a peak over GAZE_PEAK_STEPS frames, then back down (a triangle),
// built rather than spelled out to avoid a wall of float literals. It fires once per segment — but ONLY
// on a leg that HAS pigs to look at — when he comes within GAZE_TRIGGER_DIST of the end, and is back to 0
// well before the braking zone (both enforced by test_model). On a pig-less leg he keeps his eyes ahead,
// so the conspicuously pig-free seg16 also loses the habitual glance.
const GAZE_STEP_DEG = 0.45;    // degrees of head-turn added per frame
const GAZE_PEAK_STEPS = 20;    // frames up to the peak (= 9deg), then back down
export const GAZE_SEQUENCE: number[] = [];
for (let i = 1; i <= GAZE_PEAK_STEPS; i++) GAZE_SEQUENCE.push(i * GAZE_STEP_DEG);        // 0.45 .. 9.0
for (let i = GAZE_PEAK_STEPS - 1; i >= 1; i--) GAZE_SEQUENCE.push(i * GAZE_STEP_DEG);    // 8.55 .. 0.45
export const GAZE_TRIGGER_DIST = 220;                                                    // begin the glance this far before the end

// the current head-turn of the distracted glance (radians), indexed by gazeStep into GAZE_SEQUENCE.
export function gazeAngle(state: RiderState): number {
  const i = state.gazeStep;
  return i >= 0 && i < GAZE_SEQUENCE.length ? GAZE_SEQUENCE[i] * (Math.PI / 180) : 0;
}

// advance the glance one frame: once armed (>=0) step toward done (capped), else arm at the trigger — but
// only on a leg with pigs to glance at. Frame-based (one frame per sequence entry), not distance-based;
// the 300m-min segments + the trigger window guarantee it finishes before the braking zone (test).
function nextGazeStep(gazeStep: number, distToEnd: number, hasPigs: boolean): number {
  if (gazeStep >= 0) return Math.min(gazeStep + 1, GAZE_SEQUENCE.length);
  return hasPigs && distToEnd <= GAZE_TRIGGER_DIST ? 0 : -1;
}

// THE GAZE STEP — run AFTER the bike has moved this frame: returns the state with its glance advanced.
// Mid-turn the eyes are on the road (glance parked at -1); otherwise it arms/advances purely from how far
// he NOW is from the segment's end and whether the segment has pigs. (It reads the post-move along, so the
// glance is keyed off the bike's new progress — a frame's worth of imprecision the distraction shrugs off.)
const EYES_ON_ROAD_YAW = 6 * Math.PI / 180;   // pointed more than this off the lane = mid-corner, no glancing

export function nextRiderGaze(state: RiderState, world: World): RiderState {
  return state.gazeStep === -1 ? state : { ...state, gazeStep: -1 };   // TEMP: pig-distraction disabled — keep eyes ahead to isolate the turning feel
  if (Math.abs(state.yaw) > EYES_ON_ROAD_YAW) return state.gazeStep === -1 ? state : { ...state, gazeStep: -1 };
  const seg = world.segments[state.segment];
  const gazeStep = nextGazeStep(state.gazeStep, seg.length - state.along, seg.pigs);
  return gazeStep === state.gazeStep ? state : { ...state, gazeStep };
}
