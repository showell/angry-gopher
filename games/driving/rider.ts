// rider.ts — the RIDER: his state (position, velocity, heading, lean, gaze) and how he decides to move,
// one frame at a time. Pure and node-testable (test/test_model.ts); no canvas, no world coordinates — a
// segment relates to its neighbour only by a turn ANGLE.
//
// WHAT THE RIDER WANTS (his whole personality, in four rules):
//   • Go fast — accelerate at a constant rate whenever the road ahead is clear, up to V_MAX.
//   • Don't run over the cat — while a cat is crossing inside its danger window he HOLDS the throttle
//     (stops accelerating) until it's clear; he never brakes for it, just stops closing on it.
//   • Turn safely but quickly — brake to a tabulated safe entry speed for the corner, then lean into it and
//     let the tilt bring his heading around, straightening back out as he fills the lane to the far edge.
//   • Glance at the pigs — a brief VIEW-ONLY head-turn toward the roadside pigs and back as he nears a
//     turn; it never touches the path or the physics. The gaze is its OWN step, run after the bike moves
//     each frame — the logic lives in rider_gaze.ts (the caller runs bike-then-gaze; see getNextRiderState).
//
// HOW HE MOVES, FRAME BY FRAME: position is relative to the CURRENT segment — along (progress), across
// (lateral offset, + = right), yaw (heading vs the segment), v (speed, m/press), plus the bike's tilt (lean)
// carried in `turn`. Each press getNextRiderState makes a forward decision (getForwardAccelDecel: throttle/
// brake) and a rotational one (the lean): the rider tips the bike a notch further into the corner, and the
// tilt — leading by a frame — yaws his heading by YAW_PER_TILT per unit of tilt. Cruising keeps across/yaw at 0
// (bike upright) and advances along by v. Every turn is a straighten-out (no rigid arcs): the moment he crosses
// the next segment's inner-edge extension he's re-expressed in that segment's frame, still pointed the old way,
// then leans his heading back toward 0 while drifting to the far edge.

import type { World } from './world.ts';
import type { RoadSegment, SegId } from './road_segment.ts';
import { turnSpeed } from './intersection.ts';
import { segmentCatDanger } from './cat_motion.ts';

// ----------------------------------------------------------------------------
// types
// ----------------------------------------------------------------------------

// Which road edge the rider's projected arc would run off FIRST (NONE = he stays on the road). The rider
// leans AWAY from the danger: LEFT -> tilt right, RIGHT -> tilt left. See getDangerInfo.
export const DangerSide = { LEFT: 'LEFT', NONE: 'NONE', RIGHT: 'RIGHT' } as const;
export type DangerSide = typeof DangerSide[keyof typeof DangerSide];

// The danger projection's verdict: which side he'd run off, and in how many steps (the full horizon when NONE).
export interface DangerInfo { side: DangerSide; steps: number }

// A HUD-only readout of the last forward+lean decision getNextRiderState made — NOT part of the rider's
// state, just the most recent frame's internal choices surfaced for the debug overlay. (Reflects the last
// FORWARD step; on reverse it goes momentarily stale, which the diagnostic HUD tolerates.)
export interface RiderDebug { accel: number; tiltStep: number; headingChange: number; yawFromTarget: number; tiltSnapped: boolean; yawAimed: boolean }
let lastDebug: RiderDebug = { accel: 0, tiltStep: 0, headingChange: 0, yawFromTarget: 0, tiltSnapped: false, yawAimed: false };
export function riderDebug(): RiderDebug { return lastDebug; }

// The whole game is seen through the RIDER (on a motorcycle, treated as a single POINT, which keeps the
// physics simple). A RiderState is everything we know about him this frame:
//   POSITION : segment + along (progress) + across (lateral offset) + yaw (heading vs the segment)
//   VELOCITY : v (speed along the path, m/press)
//   LEAN     : tilt (the bike's roll — 0 when upright; it's what turns the bike, see getNextRiderState)
// There is no "turning" mode any more: the rider is always just driving, sometimes leaned. `gazeStep` carries
// the glance.
export interface RiderState {
  segment: SegId;
  along: number;
  across: number;
  yaw: number;        // the bike's heading offset from straight down the lane (rad; + = pointed right)
  v: number;          // speed along the path (m/press)
  tilt: number;       // the bike's lean (rad; + = leaned right). Yaws the heading at YAW_PER_TILT per unit.
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

// A reference lean angle the renderer scales its focal pull-in against (camera effects saturate near it).
// No longer a hard cap on the physics: the rider's tilt is now free state (getNextRiderState), and with a
// low YAW_PER_TILT he may lean well past this to carve a sharp turn.
export const MAX_LEAN = 20 * Math.PI / 180;

// straighten-out tuning. Every turn is a straighten-out (no rigid arcs); the geometry requires the turn
// angle to be at most 90deg — beyond that the Rider would enter the next segment pointed backwards.
// test/test_model.ts enforces it on the configured route.
export const MAX_TURN_ANGLE = 90 * Math.PI / 180;   // the largest turn the model allows
const STRAIGHTEN_MARGIN = 0.05;             // hard safety: keep the drift bulge at least this far inside the edge (m)
const DANGER_STEPS = 15;                     // FORWARD brake: slow for the road edge once it's within this many frames at the current speed
const TURN_DANGER_STEPS = 120;              // STEERING look-ahead: project the rider's arc this many frames to pick which way to lean (longer = more anticipation, less oversteer)
const TILT_STEP = 1 * Math.PI / 180;        // the most the rider leans further into the turn in one frame (prorated by danger nearness)
const TILT_SNAP = 0.5 * Math.PI / 180;      // part of the snap-to-centre window: the lean must be within this of upright
const YAW_EPSILON = 0.5 * Math.PI / 180;    // part of the snap-to-centre window: the heading must be within this of straight
const AIMING_DISTANCE = 100;                // when upright, the rider aims his heading at the lane centre this far ahead (m) — eases him back to the middle
const YAW_PER_TILT = 0.2;                   // the lean's leverage on the bike: every degree of tilt yaws the heading 0.2deg (so a turn demands a deep lean)

const clamp = (x: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, x));

// The heading that points the rider at the lane CENTRE, AIMING_DISTANCE ahead, from a lateral offset `across`
// (0 when centred; tilts back toward the middle when off to a side). His straighten-out target — used both to
// snap him clean (getNextRiderState) and to treat OVERSHOOTING it as a danger (getDangerInfo).
function aimYawFor(across: number): number {
  return Math.atan2(-across, AIMING_DISTANCE);
}

// ----------------------------------------------------------------------------
// functions
// ----------------------------------------------------------------------------

export function initialRiderState(world: World): RiderState {
  return { segment: world.start, along: 0, across: 0, yaw: 0, v: V_BASE, tilt: 0, gazeStep: -1 };
}

// The Rider's heading relative to north (north = seg1's forward direction). This is the one ABSOLUTE
// orientation we expose: far scenery (the horizon) is drawn purely from it, because a mountain at
// infinity depends on which way the Rider faces, not where it is. Continuous across segment crossings.
export function riderHeading(state: RiderState, world: World): number {
  return world.segments[state.segment].northHeading + state.yaw;
}

// The rider's lean (camera roll): the bike's TILT — 0 when upright. The renderer reads it directly as the
// camera roll, the focal pull-in, and a subtle head-yaw into the corner.
export function riderTilt(state: RiderState): number {
  return state.tilt;
}

// Has the rider reached the end of the route — at rest at the end of the final (exit-less) segment?
export function riderFinished(rider: RiderState, world: World): boolean {
  const lastId = world.order[world.order.length - 1];
  return rider.segment === lastId && rider.along >= world.segments[lastId].length - 1e-6;
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

// Advance the BIKE one frame. The rider makes two decisions — a forward one (throttle/brake, getForwardAccelDecel)
// and a rotational one (lean, steered by getDangerInfo) — which we integrate into the new velocity, heading, and
// position, then resolve where that lands him on the road graph BY POSITION (there is no turning "mode"). Pure;
// the gaze is carried through unchanged and advanced separately (the caller runs nextRiderGaze right after).
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];

  const v = state.v + getForwardAccelDecel(state, seg, world);                  // the forward decision IS the new speed

  // The LEAN drives the turn. The rider projects his arc (getDangerInfo) and tips the bike AWAY from whichever
  // shoulder he'd run off first — LEFT danger -> lean right, RIGHT danger -> lean left, NONE -> hold. The lean
  // adjustment is PRORATED by how close the danger is: a full TILT_STEP when it's imminent, fading to ~0 at the
  // horizon (we trust him not to overreact to far-off danger — that's the damping). The lean carried IN from
  // last frame yaws the bike YAW_PER_TILT per unit, so the tilt LEADS the yaw by a frame.
  const prevTilt = state.tilt;
  const danger = getDangerInfo(state, seg);
  const tiltStep = TILT_STEP * (TURN_DANGER_STEPS - danger.steps) / TURN_DANGER_STEPS;   // closer danger -> bigger lean
  let tilt = danger.side === DangerSide.LEFT ? prevTilt + tiltStep
           : danger.side === DangerSide.RIGHT ? prevTilt - tiltStep
           : prevTilt;
  const headingChange = YAW_PER_TILT * prevTilt;
  let yaw = state.yaw + headingChange;
  const midHeading = state.yaw + headingChange / 2;                            // average heading over the frame -> arc
  const along = state.along + v * Math.cos(midHeading);
  const across = state.across + v * Math.sin(midHeading);
  // SNAP-TO-CENTRE — the heading we want is aimYaw: pointed at the lane CENTRE, AIMING_DISTANCE ahead (it's
  // NOT 0 when he sits off-centre). Only when he's BOTH nearly upright (|tilt| < TILT_SNAP) AND already
  // nearly on that aim (|yaw - aimYaw| < YAW_EPSILON) do we tidy him clean: lean to exactly 0 and heading
  // onto aimYaw, so he eases back to the middle. Requiring BOTH means a turn (deep lean OR a heading far off
  // the aim) can never trigger it mid-corner — the snap only kills the last wobble as he settles straight.
  const aimYaw = aimYawFor(across);
  const yawFromTarget = yaw - aimYaw;                            // signed: how far the natural heading sits from the aim (abs gates the snap)
  const snapped = Math.abs(tilt) < TILT_SNAP && Math.abs(yawFromTarget) < YAW_EPSILON;
  if (snapped) { tilt = 0; yaw = aimYaw; }

  lastDebug = { accel: v - state.v, tiltStep: tilt - prevTilt, headingChange, yawFromTarget, tiltSnapped: snapped, yawAimed: snapped };   // HUD readout of this frame's choices

  const riderState: RiderState = { segment: seg.id, along, across, yaw, v, tilt, gazeStep: state.gazeStep };

  // Resolve the road graph by POSITION (not by any turn flag): on reaching the commit point, cross into the
  // next segment; at a terminus, stop dead at the end.
  const exitIxn = world.intersections[seg.exitIxn];
  if (exitIxn.to !== null && along >= seg.alongWhereRiderCommitsToTurn)
    return riderStateForNextSegment(riderState, world);
  if (exitIxn.to === null && along >= seg.length)
    return { ...riderState, along: seg.length, v: 0 };
  return riderState;
}

// Re-express the rider onto the NEXT segment as he commits to the turn: he keeps his speed AND his lean (the
// bike's roll is physically continuous across the seam) but lands on the new segment's inner edge, now pointed
// the old way relative to the new direction — a touch before its begin line (negative along), the same physical
// point, so motion stays continuous — and straightens out from there, eyes on the road.
function riderStateForNextSegment(riderState: RiderState, world: World): RiderState {
  const seg = world.segments[riderState.segment];
  const exitIxn = world.intersections[seg.exitIxn];
  const next = world.segments[exitIxn.to as string], hw = seg.width / 2, theta = exitIxn.angle, sgn = exitIxn.sign;
  return { segment: next.id, along: -hw / Math.sin(theta), across: sgn * hw, yaw: -sgn * theta,
           v: riderState.v, tilt: riderState.tilt, gazeStep: -1 };
}

// THE FORWARD DECISION — throttle/brake — returned as the change in speed this frame (state.v + this is the
// new speed; V_MAX and the >=0 floor are baked in). One obstacle-reactive rule, no cruising/turning phases: he
// WANTS to accelerate, but takes the most restrictive (minimum) of three brakes — the upcoming corner (reach
// its safe entry speed by the commit point), a crossing cat (hold the throttle), and the road edge/shoulder
// (kinematic-brake to arrive at it at v=0). When approaching the corner he won't crawl below its entry speed.
function getForwardAccelDecel(state: RiderState, seg: RoadSegment, world: World): number {
  let a = A_ACCEL;

  // brake for the upcoming corner: the constant decel (v^2 = vEnd^2 + 2*a*d) that lands him at the corner's
  // safe entry speed right at the commit point, recomputed each press so it self-corrects integration drift.
  const vEnd = turnSpeed(world.intersections[seg.exitIxn]);   // safe entry speed (0 at a terminus)
  const near = nearIntersection(state, seg);
  if (near) {
    const d = seg.alongWhereRiderCommitsToTurn - state.along;
    a = Math.min(a, d <= 1e-6 ? 0 : (vEnd * vEnd - state.v * state.v) / (2 * d));
  }
  if (segmentCatDanger(seg.cats, state.along, state.v)) a = Math.min(a, 0);   // hold throttle for a crossing cat
  if (isInDangerOfHittingShoulder(state, seg))                               // brake to stop before the shoulder
    a = Math.min(a, -state.v * state.v / (2 * shoulderDistance(state, seg)));

  let v = clamp(state.v + a, 0, V_MAX);
  if (near) v = Math.max(v, vEnd);   // don't crawl below the corner's entry speed approaching it
  return v - state.v;
}

// Is the Rider close enough to the upcoming intersection to start slowing for it? Every segment exits
// through an intersection (a turn, or the terminus), so this is just "within braking distance of the end".
function nearIntersection(state: RiderState, seg: RoadSegment): boolean {
  return seg.length - state.along <= APPROACH_INTERSECTION_DIST;
}

// How far the rider would travel, holding his CURRENT heading, before running off the road shoulder on the
// side he's drifting toward — Infinity when he's pointed (near) straight down the lane. `room` is the lateral
// gap to that edge; the danger side is set by his HEADING, not which side of centre he's on (heading left, the
// left shoulder is the danger side wherever he sits), and it's floored at the safety margin. Dividing by
// sin(yaw) turns the lateral gap into distance along his heading.
function shoulderDistance(state: RiderState, seg: RoadSegment): number {
  const sin = Math.abs(Math.sin(state.yaw));
  if (sin <= 1e-6) return Infinity;
  const room = Math.max(STRAIGHTEN_MARGIN, seg.width / 2 - STRAIGHTEN_MARGIN - state.across * Math.sign(state.yaw));
  return room / sin;
}

// Is the rider close enough to the shoulder that, holding this heading, he'd reach it within DANGER_STEPS
// frames at his current speed? The forward decision brakes for it; the rotational decision will lean on it too.
function isInDangerOfHittingShoulder(state: RiderState, seg: RoadSegment): boolean {
  return shoulderDistance(state, seg) < DANGER_STEPS * state.v;
}

// The rider's "brain": project his ARC forward (tilt held constant -> a constant heading-change per step,
// speed held constant) and report the FIRST danger that would force a correction, or NONE over the next
// TURN_DANGER_STEPS. There are TWO kinds of danger, and the SOONER one wins:
//   • running off a road shoulder (across past +/-hw) — the hard limit, and
//   • his heading OVERSHOOTING the aim (aimYawFor: the lane-centre target he straightens onto). Coming out
//     of a turn the overshoot is usually sooner, and catching it is what stops the oversteer:
//       - heading LEFT of the aim  -> off-road is the LEFT shoulder; the RIGHT danger is yaw crossing UP past
//         the aim (about to sail past centre to the right).
//       - heading RIGHT of the aim -> mirror: off-road is the RIGHT shoulder; the LEFT danger is crossing DOWN.
// He leans AWAY from whichever side this names, so a looming overshoot eases his lean before he passes centre.
export function getDangerInfo(state: RiderState, seg: RoadSegment): DangerInfo {
  const hw = seg.width / 2;
  const headingStep = YAW_PER_TILT * state.tilt;                            // constant per step (tilt held fixed)
  let yaw = state.yaw, across = state.across;
  const aimSide = Math.sign(yaw - aimYawFor(across));                       // <0: heading left of the aim, >0: right of it
  for (let i = 0; i < TURN_DANGER_STEPS; i++) {
    across += state.v * Math.sin(yaw + headingStep / 2);                    // arc step (midpoint heading)
    yaw += headingStep;
    if (across <= -hw) return { side: DangerSide.LEFT, steps: i };          // i = safe steps before the event (0 = imminent)
    if (across >= hw) return { side: DangerSide.RIGHT, steps: i };
    const rel = yaw - aimYawFor(across);                                    // signed gap from the (moving) aim
    if (aimSide < 0 && rel >= 0) return { side: DangerSide.RIGHT, steps: i };   // was left of aim, crossed past -> overshooting right
    if (aimSide > 0 && rel <= 0) return { side: DangerSide.LEFT, steps: i };    // was right of aim, crossed past -> overshooting left
  }
  return { side: DangerSide.NONE, steps: TURN_DANGER_STEPS };
}

// The same arc getDangerInfo walks, but recording every point (centre-relative along/across in the
// CURRENT segment's frame) instead of just the first shoulder crossing — so the renderer can draw the
// rider's projected path: where his current tilt + speed would carry him over the next TURN_DANGER_STEPS.
// It's literally "what the rider sees" when he decides which way to lean. Mirrors getNextRiderState's
// integration (midpoint heading, constant tilt -> constant headingStep, constant v).
export function projectedPath(state: RiderState): { along: number; across: number }[] {
  const headingStep = YAW_PER_TILT * state.tilt;
  let yaw = state.yaw, along = state.along, across = state.across;
  const path: { along: number; across: number }[] = [];
  for (let i = 0; i < TURN_DANGER_STEPS; i++) {
    const mid = yaw + headingStep / 2;                                      // average heading over the step -> arc
    along += state.v * Math.cos(mid);
    across += state.v * Math.sin(mid);
    path.push({ along, across });
    yaw += headingStep;
  }
  return path;
}
