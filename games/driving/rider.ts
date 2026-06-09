// rider.ts — the RIDER: his state (position, velocity, heading, lean, gaze) and how he decides to move,
// one frame at a time. Pure and node-testable (test/test_model.ts); no canvas, no world coordinates — a
// segment relates to its neighbour only by a turn ANGLE.
//
// WHAT THE RIDER WANTS (his whole personality, in four rules):
//   • Go fast — accelerate at a constant rate whenever the road ahead is clear, up to V_MAX.
//   • Don't run over the cat — while a cat is crossing inside its danger window he HOLDS the throttle
//     (stops accelerating) until it's clear; he never brakes for it, just stops closing on it.
//   • Turn safely but quickly — brake to a tabulated safe entry speed for the corner, then straighten
//     out through it at a fixed, jerk-limited rate, drifting across to fill the lane to the far edge.
//   • Glance at the pigs — cruising up to a turn he briefly turns his head toward the roadside pigs,
//     then puts his eyes back on the road before braking. A VIEW-ONLY distraction; it never touches
//     the path or the physics.
//
// HOW HE MOVES, FRAME BY FRAME: position is relative to the CURRENT segment — along (progress), across
// (lateral offset, + = right), angle (heading vs the segment), v (speed, m/press). Cruising keeps
// across/angle at 0 and advances along by v; accel() is a pure function of (along, v, distance-to-the-
// next-intersection). Every turn is a straighten-out (no rigid arcs): the moment he crosses the next
// segment's inner-edge extension he is re-expressed in that segment's frame, still pointed the old way,
// then rotates his heading to 0 (at TURN_OMEGA, jerk-limited) while drifting to the far edge, and finally
// eases back to centre. See accel()/cruise() and enterStraighten()/straightenStep().

import type { World } from './world.ts';
import type { RoadSegment, SegId } from './road_segment.ts';
import { turnSpeed } from './intersection.ts';
import { segmentCatDanger } from './cat_motion.ts';

// ----------------------------------------------------------------------------
// types
// ----------------------------------------------------------------------------

export interface Turning { angle: number; phase: 'straightening' | 'recentering'; turnRate: number }

// The whole game is seen through the RIDER (on a motorcycle, treated as a single POINT, which keeps the
// physics simple). A RiderState is everything we know about him this frame:
//   POSITION : segment + along (progress) + across (lateral offset) + angle (heading vs the segment)
//   VELOCITY : v (speed along the path, m/press)
// `turn` is null while cruising; a small descriptor while turning. `gazeStep` carries the glance.
export interface RiderState {
  segment: SegId;
  along: number;
  across: number;
  angle: number;
  v: number;          // speed along the path (m/press)
  turn: Turning | null;
  gazeStep: number;   // the "distracted rider" glance: -1 = eyes ahead, 0..8 = mid-glance, >=9 = done
}

// ----------------------------------------------------------------------------
// constants — motion is per-press (not metres) unless a comment says otherwise
// ----------------------------------------------------------------------------

export const V_BASE = 0.3;    // speed at the very start of the drive (m/press)
export const A_ACCEL = 0.015; // constant acceleration while the intersection is still far off (m/press^2)
const V_MAX = 2.5;            // top speed — the bike never accelerates past this

// the Rider starts slowing once the next intersection is within this distance (metres)
export const APPROACH_INTERSECTION_DIST = 60;

// camera roll: the rider banks INTO the turn, directly proportional to how fast he's rotating the bike
// (the per-press heading change), with NO easing. See leanFor().
export const LEAN_PER_OMEGA = 10;             // lean (rad) per rad of per-press heading change (~10deg on an 80deg turn)
export const LEAN_CAP = 45 * Math.PI / 180;  // hard runtime cap on the lean
// the tilt may change at most this much per press — no sharp banking. Since tilt = LEAN_PER_OMEGA * the
// per-press rotation, this caps how fast the rotation rate may change.
const MAX_TILT_STEP = 1 * Math.PI / 180;
const TURN_RATE_STEP = MAX_TILT_STEP / LEAN_PER_OMEGA;

// The rider leans at most this much, and the per-press rotation is capped to match, so a straighten-out
// never banks past it. This single ceiling replaced the old angle-scaled omegaFor: the ROTATION RATE is
// now one constant for every turn, and what varies by angle is the entry speed (turnSpeed, tabulated).
export const MAX_LEAN = 20 * Math.PI / 180;
export const TURN_OMEGA = MAX_LEAN / LEAN_PER_OMEGA;   // max heading turned per press (rad)

// straighten-out tuning. Every turn is a straighten-out (no rigid arcs); the geometry requires the turn
// angle to be at most 90deg — beyond that the Rider would enter the next segment pointed backwards.
// test/test_model.ts enforces it on the configured route.
export const MAX_TURN_ANGLE = 90 * Math.PI / 180;   // the largest turn the model allows
const STRAIGHTEN_MARGIN = 0.1;              // hard safety: keep the drift bulge at least this far inside the edge (m)
const RECENTER_DISTANCE = 30;               // recenter lean = -across/this; bigger = gentler lean, slower return to centre
const ALIGN_EPS = 0.02;                     // "aligned" once |angle| is below this (rad)
const CENTER_EPS = 0.05;                    // "centred" once |across| is below this (m)
const QUARTER = Math.PI / 2;

// the "distracted rider": a slow glance toward the roadside pigs and back (~40 frames), built rather
// than spelled out to avoid a wall of float literals. It fires once per segment — but ONLY on a leg
// that actually HAS pigs to look at — when he comes within GAZE_TRIGGER_DIST of the end, and is back
// to 0 well before the braking zone (both enforced by test_model). On a pig-less leg he keeps his
// eyes ahead, so the conspicuously pig-free seg16 also loses the habitual glance. Gaze is a VIEW
// offset only: the renderer adds it as a camera yaw (see main.ts/view.ts).
const GAZE_STEP_DEG = 0.45;    // degrees of head-turn added per frame
const GAZE_PEAK_STEPS = 20;    // frames up to the peak (= 9deg), then back down
export const GAZE_SEQUENCE: number[] = [];
for (let i = 1; i <= GAZE_PEAK_STEPS; i++) GAZE_SEQUENCE.push(i * GAZE_STEP_DEG);        // 0.45 .. 9.0
for (let i = GAZE_PEAK_STEPS - 1; i >= 1; i--) GAZE_SEQUENCE.push(i * GAZE_STEP_DEG);    // 8.55 .. 0.45
export const GAZE_TRIGGER_DIST = 220;                                                    // begin the glance this far (game units) before the end

const clamp = (x: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, x));

// ----------------------------------------------------------------------------
// functions
// ----------------------------------------------------------------------------

export function initialRiderState(world: World): RiderState {
  return { segment: world.start, along: 0, across: 0, angle: 0, v: V_BASE, turn: null, gazeStep: -1 };
}

// The Rider's heading relative to north (north = seg1's forward direction). This is the one ABSOLUTE
// orientation we expose: far scenery (the horizon) is drawn purely from it, because a mountain at
// infinity depends on which way the Rider faces, not where it is. Continuous across segment crossings.
export function riderHeading(state: RiderState, world: World): number {
  return world.segments[state.segment].northHeading + state.angle;
}

// The rider's lean / camera roll for a per-press heading change `dHeading`. He banks INTO the turn —
// sign and size track the rotation directly (no easing), then capped.
export function leanFor(dHeading: number): number {
  return clamp(LEAN_PER_OMEGA * dHeading, -LEAN_CAP, LEAN_CAP);
}

// The rider's lean across one frame (prev -> curr): the lean for the heading change between the two
// states. The renderer reads it as the camera roll (and the focal pull-in / head-yaw into the corner).
export function riderLean(prev: RiderState, curr: RiderState, world: World): number {
  return leanFor(riderHeading(curr, world) - riderHeading(prev, world));
}

// Has the rider reached the end of the route — at rest at the end of the final (exit-less) segment?
export function riderFinished(rider: RiderState, world: World): boolean {
  const lastId = world.order[world.order.length - 1];
  return rider.segment === lastId && !rider.turn && rider.along >= world.segments[lastId].length - 1e-6;
}

// the current head-turn of the distracted glance (radians), indexed by gazeStep into GAZE_SEQUENCE.
export function gazeAngle(state: RiderState): number {
  const i = state.gazeStep;
  return i >= 0 && i < GAZE_SEQUENCE.length ? GAZE_SEQUENCE[i] * (Math.PI / 180) : 0;
}

// advance the glance one cruise-frame: once armed (>=0) step toward done (capped), else arm at the
// trigger — but only on a leg with pigs to glance at. Frame-based (one frame per sequence entry), not
// distance-based — but the 300m-min segments + the trigger window guarantee it finishes before the
// braking zone (enforced by test).
function nextGazeStep(gazeStep: number, distToEnd: number, hasPigs: boolean): number {
  if (gazeStep >= 0) return Math.min(gazeStep + 1, GAZE_SEQUENCE.length);
  return hasPigs && distToEnd <= GAZE_TRIGGER_DIST ? 0 : -1;
}

// Advance the Rider one frame. Pure: (RiderState, World) -> the next RiderState. Called explicitly
// before each draw; the returned state is what the renderer is handed.
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];
  const next = state.turn === null ? cruise(state, seg, world) : straightenStep(state, seg);
  assertInvariants(next, world);
  return next;
}

// Is the Rider close enough to the upcoming intersection to start slowing for it? Every segment exits
// through an intersection (a turn, or the terminus), so this is just "within braking distance of the end".
function nearIntersection(state: RiderState, seg: RoadSegment): boolean {
  return seg.length - state.along <= APPROACH_INTERSECTION_DIST;
}

// Acceleration (m/press^2) PURELY from position, velocity, and distance-to-turn:
//   intersection still far -> keep accelerating at a constant rate.
//   intersection near       -> the EXACT constant deceleration that lands the Rider at the exit's turn
//     speed (0 at the terminus, so he coasts to a stop) right at the commit point, from
//     v^2 = vEnd^2 + 2*a*d. Recomputed every press: constant-decel kinematics are self-consistent, so
//     this reproduces the same a each press while correcting integration drift. (The terminus is just an
//     intersection with turn speed 0 — no exit-less special case.)
function accel(state: RiderState, seg: RoadSegment, world: World): number {
  if (!nearIntersection(state, seg)) return A_ACCEL;
  const d = seg.alongWhereRiderCommitsToTurn - state.along;
  if (d <= 1e-6) return 0;
  const vEnd = turnSpeed(world.intersections[seg.exitIxn]);
  return (vEnd * vEnd - state.v * state.v) / (2 * d);
}

function cruise(state: RiderState, seg: RoadSegment, world: World): RiderState {
  // A cat crossing the road just ahead: the rider sees it and HOLDS OFF the throttle (never accelerates
  // toward it) — but braking for an intersection still applies. He doesn't slow for the cat, he just
  // stops speeding up, so it clears in front of him by the frame he arrives.
  let a = accel(state, seg, world);
  if (segmentCatDanger(seg.cats, state.along, state.v)) a = Math.min(a, 0);
  let v = clamp(state.v + a, 0, V_MAX);
  const exitIxn = world.intersections[seg.exitIxn];

  if (exitIxn.to === null) {   // the terminus: coast to the end (braked by accel), then the game is over
    const along = state.along + v;
    const gazeStep = nextGazeStep(state.gazeStep, seg.length - along, seg.pigs);
    if (along >= seg.length) return { ...state, along: seg.length, v: 0, gazeStep };   // reached the end -> stop
    return { ...state, along, v, gazeStep };
  }

  // braked to the lane-filling speed; cross the inner edge and straighten into the next
  if (nearIntersection(state, seg)) v = Math.max(v, turnSpeed(exitIxn));   // never crawl below the lane-filling speed
  const along = state.along + v;
  if (along < seg.alongWhereRiderCommitsToTurn) {   // cross the inner edge -> commit to the next segment
    const gazeStep = nextGazeStep(state.gazeStep, seg.length - along, seg.pigs);
    return { ...state, along, v, gazeStep };
  }
  return enterStraighten(seg, world, v);
}

// Crossing into a turn: the moment the Rider crosses the extension of the next segment's INNER edge (at
// alongWhereRiderCommitsToTurn on this segment) we re-express him in the next segment's frame and
// straighten out. Crossing that edge, the Rider lands ON the inner edge (across = sgn*hw — the right
// edge for a right turn), still pointed the OLD way (angle = -sgn*theta), and a touch BEFORE the new
// segment's begin line (along = -hw/sin(theta), negative — expected). Same physical point, so continuous.
function enterStraighten(seg: RoadSegment, world: World, v: number): RiderState {
  const ixn = world.intersections[seg.exitIxn];
  const next = world.segments[ixn.to as string];   // a turn (not a terminus): cruise only reaches here for ixn.to != null
  const sgn = ixn.sign, theta = ixn.angle, hw = seg.width / 2;
  return {
    segment: next.id,
    along: -hw / Math.sin(theta),
    across: sgn * hw,
    angle: -sgn * theta,
    v,
    turn: { angle: theta, phase: 'straightening', turnRate: 0 },
    gazeStep: -1,   // eyes back on the road through the turn; re-arms on the new segment
  };
}

// One press of straighten-out, run in two EXPLICIT, SEQUENTIAL phases carried in turn.phase. (Deriving
// the phase from |angle| each press instead caused a wiggle: the recenter lean raised |angle| past the
// threshold, which flipped the bike back into "still misaligned, kill the angle", which rotated it
// straight again — a bang-bang oscillation. The phase, once advanced, never reverts.)
//   (1) 'straightening' — ANGLE-KILL (urgent): rotate the heading to 0 at TURN_OMEGA, holding the lane-
//       filling speed; the bike arcs across to the far edge. v_safe is the hard road-edge cap. Heading
//       reaches 0 -> finish (if already centred) or hand off to recenter.
//   (2) 'recentering' — at leisure: aim at the centre line RECENTER_DISTANCE ahead, so the offset closes
//       LINEARLY and the Rider is back at centre that far down the road. Re-accelerating; resume
//       cruising once centred (the residual lean is tiny).
function straightenStep(state: RiderState, seg: RoadSegment): RiderState {
  const hw = seg.width / 2;
  const t = state.turn as Turning;
  // Rotate at a FIXED ceiling, the same for every turn — the lean it produces is MAX_LEAN. What varies
  // by angle is the entry speed (turnSpeed): the sim picked each so this rotation rate sweeps the drift
  // exactly to the far edge without overshooting it.
  const omega = TURN_OMEGA;
  const killing = t.phase === 'straightening';     // angle-kill

  // angle-kill drives the heading to 0. The recentre leans PROPORTIONALLY to how far off the Rider still
  // is (aim = -across/RECENTER_DISTANCE): far off -> leaned -> drifting in; as he nears the centre the
  // lean fades on its own, so he arrives upright with no residual to snap out (lean and offset reach 0
  // together).
  const aim = killing ? 0 : -state.across / RECENTER_DISTANCE;
  // Approach the aim on a BRAKING profile: cap the rotation rate to what can still decelerate (at
  // TURN_RATE_STEP/press) to 0 by the time the heading reaches the aim — sqrt(2*step*gap). So the heading
  // SETTLES onto the aim instead of coasting past it and wobbling (the rate can't change instantly, so
  // without braking it always overshoots a moving target).
  const gap = aim - state.angle;
  const lim = Math.min(omega, Math.sqrt(2 * TURN_RATE_STEP * Math.abs(gap)));
  const desired = clamp(gap, -lim, lim);
  // JERK-LIMIT: tilt = LEAN_PER_OMEGA * the per-press rotation, so capping how much the rotation may
  // change per press (TURN_RATE_STEP) caps the tilt change to MAX_TILT_STEP — no sharp banking.
  const dHeading = clamp(desired, t.turnRate - TURN_RATE_STEP, t.turnRate + TURN_RATE_STEP);
  const angle = state.angle + dHeading;

  // hold the turn speed through the angle-kill (no accelerating mid-corner); re-accelerate while
  // recentring. v_safe is the hard road-edge cap: nulling the CURRENT heading a at radius R = v/omega
  // drifts R*(1 - cos a) = v*(1 - cos a)/omega toward the edge it points at, so cap v to keep that inside
  // `room`. The tabulated turnSpeed was found under this very cap, so the rider holds it through the kill
  // and fills the lane to the far edge.
  let v = killing ? state.v : state.v + A_ACCEL;
  const a = state.angle;
  if (Math.abs(a) > 1e-3) {
    // floor `room` at the margin so v_safe never reaches 0 (which would FREEZE the Rider): at the far
    // edge with a near-zero heading — the recenter about to lean back the other way — room would be ~0.
    // The heading is tiny there, so relaxing the cap is harmless.
    const room = Math.max(STRAIGHTEN_MARGIN, hw - STRAIGHTEN_MARGIN - state.across * Math.sign(a));
    v = Math.min(v, omega * room / (1 - Math.cos(a)));
  }
  v = clamp(v, 0, V_MAX);

  const mid = state.angle + dHeading / 2;
  const along = state.along + v * Math.cos(mid);
  const across = state.across + v * Math.sin(mid);

  const aligned = Math.abs(angle) < ALIGN_EPS, centred = Math.abs(across) < CENTER_EPS;
  // hand off to cruise only when the incoming heading is already within one tilt-step of 0, so zeroing
  // it (this frame's delta is -state.angle) is itself a <= MAX_TILT_STEP change.
  if (centred && Math.abs(state.angle) < TURN_RATE_STEP) return { segment: seg.id, along, across: 0, angle: 0, v, turn: null, gazeStep: state.gazeStep };
  const phase = killing && aligned ? 'recentering' : t.phase;
  return { segment: seg.id, along, across, angle, v, turn: { angle: t.angle, phase, turnRate: dHeading }, gazeStep: state.gazeStep };
}

// Invariants. The Rider may sit BEFORE a segment's start (negative along — he crosses into a turn at the
// inner edge, just shy of the begin line); this pins down "how far before is reasonable", plus the usual
// finite and bounded checks.
function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error('invariant violated: ' + msg);
}

export function assertInvariants(s: RiderState, world: World): void {
  const seg = world.segments[s.segment];
  assert(Number.isFinite(s.along) && Number.isFinite(s.across) && Number.isFinite(s.angle),
         `finite (${s.along},${s.across},${s.angle})`);
  assert(Number.isFinite(s.v) && s.v >= -1e-9 && s.v <= 8, `v sane (${s.v})`);
  assert(Math.abs(s.angle) <= QUARTER + 1e-6, `|angle| <= 90deg (${s.angle})`);
  // a turn enters at along = -hw/sin(entryAngle), before the begin line — that's expected
  const entryAngle = seg.entryIxn ? world.intersections[seg.entryIxn].angle : 0;
  const entryFloor = entryAngle > 0 ? -(seg.width / 2) / Math.sin(entryAngle) : 0;
  assert(s.along >= entryFloor - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + 1e-6, `along not past end (${s.along})`);
  assert(Math.abs(s.across) <= seg.width / 2 + 1, `across bounded (${s.across})`);
  if (s.turn === null) {
    assert(Math.abs(s.across) < 1e-6 && Math.abs(s.angle) < 1e-6, 'cruising => centred and aligned');
  } else {
    assert(s.gazeStep < 0, 'no distracted glance mid-turn (eyes on the road)');
  }
}
