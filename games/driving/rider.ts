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
//   • Glance at the pigs — a brief VIEW-ONLY head-turn toward the roadside pigs and back as he nears a
//     turn; it never touches the path or the physics. The gaze is its OWN step, run after the bike moves
//     each frame — the logic lives in rider_gaze.ts (the caller runs bike-then-gaze; see getNextRiderState).
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
export const A_ACCEL = 0.010; // constant acceleration while the intersection is still far off (m/press^2)
export const V_MAX = 2.5;     // top speed — the bike never accelerates past this (the truck caps off this too)

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

// How far the rider has driven ALONG the route: the lengths of every segment behind his current one
// plus his along on it. Treats each joint as zero-length (segments abut at the inner edge) — monotonic
// and exact enough for chase dynamics (truck.ts reels itself in against this). Not a global position,
// just arc-length along the 1D route.
export function routeDistance(state: RiderState, world: World): number {
  let d = 0;
  for (const id of world.order) {
    if (id === state.segment) return d + state.along;
    d += world.segments[id].length;
  }
  return d;
}

// Advance the BIKE one frame. Pure; the gaze is carried through unchanged and advanced separately (the
// caller runs nextRiderGaze right after — rider_gaze.ts).
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];

  // CRUISING the straight: accelerate (or brake for the upcoming turn), then advance along.
  if (state.turn === null) {
    const exitIxn = world.intersections[seg.exitIxn];
    let a = accel(state, seg, world);
    if (segmentCatDanger(seg.cats, state.along, state.v)) a = Math.min(a, 0);   // hold throttle for a crossing cat (never brake for it)
    let v = clamp(state.v + a, 0, V_MAX);
    if (exitIxn.to === null) {   // terminus: coast to the end and stop
      const along = state.along + v;
      return along >= seg.length ? { ...state, along: seg.length, v: 0 } : { ...state, along, v };
    }
    if (nearIntersection(state, seg)) v = Math.max(v, turnSpeed(exitIxn));   // don't crawl below the corner's entry speed
    const along = state.along + v;
    if (along < seg.alongWhereRiderCommitsToTurn) return { ...state, along, v };
    return enterStraighten(seg, world, v);   // crossed the inner edge -> commit to the turn
  }

  // TURNING: one press of straighten-out, in two phases carried in turn.phase. They're EXPLICIT and never
  // revert: deriving them from |angle| bang-bangs the bike, since the recenter lean re-crosses the
  // alignment threshold. (1) straightening: rotate the heading to 0 at the fixed ceiling, holding the
  // corner's entry speed, arcing to the far edge. (2) recentering: ease back to centre, re-accelerating.
  const turn = state.turn;
  const hw = seg.width / 2;
  const straightening = turn.phase === 'straightening';
  const aim = straightening ? 0 : -state.across / RECENTER_DISTANCE;
  // settle the rotation onto `aim` without overshoot (a brake-to-zero profile), then jerk-limit it.
  const settleRate = Math.min(TURN_OMEGA, Math.sqrt(2 * TURN_RATE_STEP * Math.abs(aim - state.angle)));
  const desired = clamp(aim - state.angle, -settleRate, settleRate);
  const dHeading = clamp(desired, turn.turnRate - TURN_RATE_STEP, turn.turnRate + TURN_RATE_STEP);
  const angle = state.angle + dHeading;

  // hold the entry speed through the angle-kill, re-accelerate while recentring — but cap v so that nulling
  // the CURRENT heading can't drift past the road edge (drift = v*(1-cos)/TURN_OMEGA, kept inside `room`).
  let v = straightening ? state.v : state.v + A_ACCEL;
  if (Math.abs(state.angle) > 1e-3) {
    const room = Math.max(STRAIGHTEN_MARGIN, hw - STRAIGHTEN_MARGIN - state.across * Math.sign(state.angle));
    v = Math.min(v, TURN_OMEGA * room / (1 - Math.cos(state.angle)));
  }
  v = clamp(v, 0, V_MAX);

  const midHeading = state.angle + dHeading / 2;   // average heading over the frame -> integrate the arc
  const along = state.along + v * Math.cos(midHeading);
  const across = state.across + v * Math.sin(midHeading);

  // hand back to cruise once centred AND zeroing the heading is itself within one tilt-step
  if (Math.abs(across) < CENTER_EPS && Math.abs(state.angle) < TURN_RATE_STEP)
    return { segment: seg.id, along, across: 0, angle: 0, v, turn: null, gazeStep: state.gazeStep };
  const phase = straightening && Math.abs(angle) < ALIGN_EPS ? 'recentering' : turn.phase;
  return { segment: seg.id, along, across, angle, v, turn: { angle: turn.angle, phase, turnRate: dHeading }, gazeStep: state.gazeStep };
}

// Is the Rider close enough to the upcoming intersection to start slowing for it? Every segment exits
// through an intersection (a turn, or the terminus), so this is just "within braking distance of the end".
function nearIntersection(state: RiderState, seg: RoadSegment): boolean {
  return seg.length - state.along <= APPROACH_INTERSECTION_DIST;
}

// Acceleration (m/press^2): constant A_ACCEL while the turn is far; once near, the exact constant decel
// (v^2 = vEnd^2 + 2*a*d) that lands the Rider at the exit's turn speed right at the commit point — 0 at a
// terminus, so he coasts to a stop. Recomputed each press, self-consistent, so it corrects drift.
function accel(state: RiderState, seg: RoadSegment, world: World): number {
  if (!nearIntersection(state, seg)) return A_ACCEL;
  const d = seg.alongWhereRiderCommitsToTurn - state.along;
  if (d <= 1e-6) return 0;
  const vEnd = turnSpeed(world.intersections[seg.exitIxn]);
  return (vEnd * vEnd - state.v * state.v) / (2 * d);
}

// Commit to the turn: re-express the Rider in the NEXT segment's frame at the inner-edge crossing. He
// lands ON the inner edge (across = sgn*hw), still pointed the old way (angle = -sgn*theta), a touch
// before its begin line (along = -hw/sin(theta), negative) — the same physical point, so continuous.
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
    gazeStep: -1,   // a fresh turning state; rider_gaze.ts keeps the eyes on the road through the turn
  };
}

