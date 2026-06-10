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
// (lateral offset, + = right), angle (heading vs the segment), v (speed, m/press). Each press,
// getNextRiderState integrates two INDEPENDENT decisions — getForwardAccelDecel (throttle/brake) and
// getRotationalAccel (lean) — into the new speed, heading, and position, then resolves the road graph.
// Cruising keeps across/angle at 0 and advances along by v. Every turn is a straighten-out (no rigid
// arcs): the moment he crosses the next segment's inner-edge extension he's re-expressed in that
// segment's frame, still pointed the old way, then rotates his heading to 0 (at TURN_OMEGA, jerk-limited)
// while drifting to the far edge, and finally eases back to centre.

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
const DANGER_STEPS = 15;                     // brake for the road edge once it's within this many frames at the current speed

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

// Advance the BIKE one frame. The rider makes two INDEPENDENT decisions — a forward one (throttle/brake)
// and a rotational one (lean) — each fully owned by its helper; here we just integrate them into the new
// velocity, heading, and position, then resolve where that lands him on the road graph. Pure; the gaze is
// carried through unchanged and advanced separately (the caller runs nextRiderGaze right after).
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];

  const v = state.v + getForwardAccelDecel(state, seg, world);                  // the forward decision IS the new speed
  const turnRate = (state.turn ? state.turn.turnRate : 0) + getRotationalAccel(state);   // and the rotational decision the new lean
  const angle = state.angle + turnRate;
  const midHeading = state.angle + turnRate / 2;                               // average heading over the frame -> arc
  const along = state.along + v * Math.cos(midHeading);
  const across = state.across + v * Math.sin(midHeading);

  // The DEFAULT next state: STAY on this segment. The turn descriptor unifies the three staying cases —
  // cruising (no turn), a turn that's centred + aligned FINISHING (no turn), or a turn carrying on (its
  // phase flips to recentering once the heading is killed). Position is the clean centre when not turning,
  // the integrated arc when turning.
  const finishing = state.turn !== null && Math.abs(across) < CENTER_EPS && Math.abs(state.angle) < TURN_RATE_STEP;
  const turn: Turning | null = state.turn === null || finishing ? null
    : { angle: state.turn.angle, turnRate, phase: state.turn.phase === 'straightening' && Math.abs(angle) < ALIGN_EPS ? 'recentering' : state.turn.phase };
  const riderState: RiderState = { segment: seg.id, along, across: turn ? across : 0, angle: turn ? angle : 0, v, turn, gazeStep: state.gazeStep };

  // The two exceptions, both for a CRUISING rider reaching the segment's exit: turn into the next segment,
  // or stop dead at a terminus.
  const exitIxn = world.intersections[seg.exitIxn];
  if (state.turn === null && exitIxn.to !== null && along >= seg.alongWhereRiderCommitsToTurn)
    return riderStateForNextSegment(riderState, world);
  if (state.turn === null && exitIxn.to === null && along >= seg.length)
    return { ...riderState, along: seg.length, v: 0 };
  return riderState;
}

// Re-express the rider onto the NEXT segment as he commits to the turn: he keeps his speed but lands on
// the new segment's inner edge, still pointed the old way, a touch before its begin line (negative along)
// — the same physical point, so motion stays continuous — and starts the straighten-out, eyes on the road.
function riderStateForNextSegment(riderState: RiderState, world: World): RiderState {
  const seg = world.segments[riderState.segment];
  const exitIxn = world.intersections[seg.exitIxn];
  const next = world.segments[exitIxn.to as string], hw = seg.width / 2, theta = exitIxn.angle, sgn = exitIxn.sign;
  return { segment: next.id, along: -hw / Math.sin(theta), across: sgn * hw, angle: -sgn * theta,
           v: riderState.v, turn: { angle: theta, phase: 'straightening', turnRate: 0 }, gazeStep: -1 };
}

// THE FORWARD DECISION — throttle/brake — returned as the change in speed this frame (state.v + this is
// the new speed; V_MAX, the >=0 floor, and the road-edge brake are all baked in). Cruising: accelerate, or
// kinematic-brake into the turn, holding the throttle (<=0) while a cat crosses, and never crawling below
// the corner's entry speed. Turning: accelerate unless the road edge is close (within DANGER_STEPS frames at
// the current heading), in which case brake kinematically to arrive at it at v=0 — one rule, no phase check.
function getForwardAccelDecel(state: RiderState, seg: RoadSegment, world: World): number {
  let v: number;
  if (state.turn === null) {
    const vEnd = turnSpeed(world.intersections[seg.exitIxn]);   // the corner's safe entry speed (0 at a terminus)
    const near = nearIntersection(state, seg);
    // far from the turn -> constant accel; near it -> the constant decel (v^2 = vEnd^2 + 2*a*d) that lands
    // him at vEnd right at the commit point, recomputed each press so it self-corrects integration drift.
    let a = A_ACCEL;
    if (near) {
      const d = seg.alongWhereRiderCommitsToTurn - state.along;
      a = d <= 1e-6 ? 0 : (vEnd * vEnd - state.v * state.v) / (2 * d);
    }
    if (segmentCatDanger(seg.cats, state.along, state.v)) a = Math.min(a, 0);   // hold throttle for a crossing cat
    v = clamp(state.v + a, 0, V_MAX);
    if (near) v = Math.max(v, vEnd);   // don't crawl below the corner's entry speed
  } else {
    // The road edge is an obstacle, treated like any other. Assume the rider HOLDS his current heading (no
    // credit for the rotation coming next frame) and measure how far along it until he'd run off the edge.
    // If that's within DANGER_STEPS frames at the current speed, brake kinematically to arrive at the edge at
    // v=0; otherwise accelerate. One rule for the whole turn — no phase check.
    let a = A_ACCEL;
    const sin = Math.abs(Math.sin(state.angle));
    if (sin > 1e-6) {
      const room = Math.max(STRAIGHTEN_MARGIN, seg.width / 2 - STRAIGHTEN_MARGIN - state.across * Math.sign(state.angle));
      const dEdge = room / sin;                                                   // distance to the edge holding this heading
      if (dEdge < DANGER_STEPS * state.v) a = -state.v * state.v / (2 * dEdge);    // brake to hit the edge at v=0
    }
    v = clamp(state.v + a, 0, V_MAX);
  }
  return v - state.v;
}

// THE ROTATIONAL DECISION — lean — returned as the change in the heading-turn rate this frame. Zero while
// cruising (bike straight; he's already pointed right). Turning: aim the rate at the target heading (0 in
// the angle-kill, the centre line RECENTER_DISTANCE ahead while recentring), settle onto it without
// overshoot (a brake-to-zero profile), and jerk-limit the change so the bank never snaps (<= MAX_TILT_STEP).
function getRotationalAccel(state: RiderState): number {
  if (state.turn === null) return 0;
  const aim = state.turn.phase === 'straightening' ? 0 : -state.across / RECENTER_DISTANCE;
  const settleRate = Math.min(TURN_OMEGA, Math.sqrt(2 * TURN_RATE_STEP * Math.abs(aim - state.angle)));
  const desired = clamp(aim - state.angle, -settleRate, settleRate);
  const dHeading = clamp(desired, state.turn.turnRate - TURN_RATE_STEP, state.turn.turnRate + TURN_RATE_STEP);
  return dHeading - state.turn.turnRate;
}

// Is the Rider close enough to the upcoming intersection to start slowing for it? Every segment exits
// through an intersection (a turn, or the terminus), so this is just "within braking distance of the end".
function nearIntersection(state: RiderState, seg: RoadSegment): boolean {
  return seg.length - state.along <= APPROACH_INTERSECTION_DIST;
}
