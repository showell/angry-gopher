// =============================================================================
// model — the pure, relational driving model. No canvas, no world coordinates,
// and (now) no absolute directions: a segment relates to its neighbour only by
// a turn ANGLE. Node-testable (test/test_model.ts).
//
// HOW THE RIDER (on a motorcycle = a point) MOVES, FRAME BY FRAME
//
// Position is relative to the CURRENT segment: along (progress), across
// (lateral offset, + = right), angle (heading relative to the segment), and v
// (speed along the path, m/press).
//
// Cruising:  across = 0, angle = 0; each press advances `along` by v, and v
//            changes by accel() — a pure function of (along, v, how-far-to-the-
//            next-intersection). Far off: constant acceleration. Within
//            APPROACH_INTERSECTION_DIST: the exact constant deceleration that
//            brings the Rider to turn speed right at the corner (recomputed each
//            press, so it self-corrects discretisation drift). See accel()/cruise().
//
// Turning (straighten-out — the ONLY turn mechanism; every turn is <= 90deg): the
// moment the Rider crosses the extension of the next segment's INNER edge he is
// re-expressed in that segment's frame, landing ON the inner edge still pointed the
// old way, then ROTATES his heading to 0 (omega = DPHI * THETA / (pi/2) per press, so
// every turn takes the same number of presses) while drifting across the lane to the
// FAR edge, and finally eases back to centre. See enterStraighten/straightenStep.
// =============================================================================

import { segmentCritters, intersectionCritters } from './critter.ts';
import type { Critter } from './critter.ts';
import { segmentTrees, TREE_ROAD_OFFSET } from './tree.ts';
import type { Scheme, Tree } from './tree.ts';

// ============================================================================
// DIMENSIONS — distances for the road & the Rider's approach to a turn, in
// METRES. (Tree sizes/placement live in tree.ts, animals in critter.ts; motion
// constants — speed, accel, spin — are per-press, below.)
// ============================================================================

// road
const LANE_WIDTH = 4;                    // a single lane
const TURN_RADIUS = 2;                   // sets the tree clear-zone tangent at each corner (R*tan(THETA/2))

// the Rider starts slowing once the next intersection is within this distance
const APPROACH_INTERSECTION_DIST = 60;

// ---- motion (per-press, not metres) ----
export const DPHI = 0.06;     // heading turned per press in a 90deg turn (rad); sets turn speed AND spin rate
export const V_BASE = 0.5;    // the Rider's speed at the very start of the drive (m/press)
export const A_ACCEL = 0.15;  // constant acceleration while the intersection is still far off (m/press^2)
const V_MAX = 5;              // top speed (m/press) — the bike never accelerates past this

// camera roll: the rider banks INTO the turn, directly proportional to how fast he's
// rotating the bike (the per-press heading change), with NO easing. See leanFor().
export const LEAN_PER_OMEGA = 6.5;            // lean (rad) per rad of per-press heading change
export const LEAN_CAP = 45 * Math.PI / 180;  // hard runtime cap on the lean

const QUARTER = Math.PI / 2;
const omegaFor = (theta: number): number => DPHI * theta / QUARTER;  // turn rate scales with angle

// ---- straighten-out tuning ----
// Every turn is a straighten-out (no rigid arcs). The geometry requires the turn angle
// to be at most 90deg — beyond that the Rider would enter the next segment pointed
// backwards. test/test_model.ts enforces it on the configured route.
export const MAX_TURN_ANGLE = 90 * Math.PI / 180;   // the largest turn the model allows
const STRAIGHTEN_MARGIN = 0.1;              // hard safety: keep the drift bulge at least this far inside the edge (m)
const RECENTER_DISTANCE = 160;
const ALIGN_EPS = 0.02;                     // "aligned" once |angle| is below this (rad)
const CENTER_EPS = 0.05;                    // "centred" once |across| is below this (m)

// ----------------------------------------------------------------------------
// World — a relational chain of segments. Scalars only; never coordinates.
// ----------------------------------------------------------------------------
export type SegId = string;
export type TurnDir = 'left' | 'right';

export interface RoadSegment {
  id: SegId;
  length: number;
  width: number;
  scheme: Scheme;                // visual theme; drives the tree colours
  trees: Tree[];
  critters: Critter[];      // roadside, along the segment (cows/pigs)
  exitCritters: Critter[];  // at the exit intersection (elephants); shared with the next segment
  exit: { dir: TurnDir; to: SegId; radius: number; angle: number } | null;
  // derived relational scalars (filled by buildWorld)
  exitSign: number;     // +1 right, -1 left, 0 none
  exitAngle: number;    // turn angle THETA (0 if none)
  exitTan: number;      // R * tan(THETA/2): the clear zone trees keep near the exit corner
  entryTan: number;     // the clear zone trees keep near the entry corner
  straightenStart: number;   // length - hw/tan(THETA): where the Rider crosses the next segment's inner edge
  entryAngle: number;        // the turn angle that FEEDS this segment (0 if none) — its entry runs negative-along
  northHeading: number;      // heading relative to north (seg1 = 0), radians — the one absolute orientation we keep
}

export interface World {
  segments: Record<SegId, RoadSegment>;
  start: SegId;
  order: SegId[];
}

// ----------------------------------------------------------------------------
// RiderState — the whole game is seen through the RIDER. The Rider is on a
// motorcycle, which is treated as a single POINT (no rectangle), which keeps the
// physics simple. A RiderState is everything we know about the Rider this frame:
//   POSITION : segment + along (progress) + across (lateral offset) + angle
//              (heading, relative to the current segment)
//   VELOCITY : v (speed along the path, m/press)
// `turn` is null while cruising; a small descriptor while turning.
// ----------------------------------------------------------------------------
export interface Turning { angle: number; phase: 'straightening' | 'recentering'; recenterEnd: number }
export interface RiderState {
  segment: SegId;
  along: number;
  across: number;
  angle: number;
  v: number;          // speed along the path (m/press)
  turn: Turning | null;
}

export function initialRiderState(world: World): RiderState {
  return { segment: world.start, along: 0, across: 0, angle: 0, v: V_BASE, turn: null };
}

// The Rider's heading relative to north (north = seg1's forward direction). This
// is the one ABSOLUTE orientation we expose: far scenery (the horizon) is drawn
// purely from it, because a mountain at infinity depends on which way the Rider
// faces, not where it is. Continuous across segment crossings (segment base + angle).
export function riderHeading(state: RiderState, world: World): number {
  return world.segments[state.segment].northHeading + state.angle;
}

const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);
const segNumber = (id: SegId): number => Number(id.slice(3));   // "seg12" -> 12
const clamp = (x: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, x));

// The rider's lean / camera roll for a per-press heading change `dHeading`. He banks
// INTO the turn — sign and size track the rotation directly (no easing), then capped.
export function leanFor(dHeading: number): number {
  return clamp(LEAN_PER_OMEGA * dHeading, -LEAN_CAP, LEAN_CAP);
}

export function buildWorld(): World {
  const DEG = Math.PI / 180;

  const seg = (id: SegId, length: number, scheme: Scheme,
               exit: RoadSegment['exit']): RoadSegment => {
    const tan = exit ? exit.radius * Math.tan(exit.angle / 2) : 0;
    return {
      id, length, width: LANE_WIDTH, scheme,
      trees: [],   // filled below, once entry/exit tangents are known
      critters: segmentCritters(length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
      exitCritters: exit ? intersectionCritters(length, signOf(exit.dir), segNumber(id), LANE_WIDTH / 2) : [],
      exit,
      exitSign: exit ? signOf(exit.dir) : 0,
      exitAngle: exit ? exit.angle : 0,
      exitTan: tan,
      entryTan: 0,
      straightenStart: exit ? length - (LANE_WIDTH / 2) / Math.tan(exit.angle) : length,
      entryAngle: 0,
      northHeading: 0,
    };
  };
  const turn = (to: SegId, dir: TurnDir, deg: number): RoadSegment['exit'] =>
    ({ dir, to, radius: TURN_RADIUS, angle: deg * DEG });

  // route is checked non-self-intersecting (no loops) and all-turns-<=-90deg by
  // test/test_model.ts. Hand-authored, opening with a soft S of gentle warm-up turns;
  // every turn is a straighten-out; the last segment has no exit (the final straight).
  const segments: Record<SegId, RoadSegment> = {
    seg1:  seg('seg1', 300, 'ALL_GREEN',     turn('seg2',  'left',   30)),
    seg2:  seg('seg2', 240, 'YELLOW_GREEN',  turn('seg3',  'right',  30)),
    seg3:  seg('seg3', 260, 'RED_GREEN',     turn('seg4',  'right',  50)),
    seg4:  seg('seg4', 320, 'ALL_GREEN',     turn('seg5',  'left',   80)),
    seg5:  seg('seg5', 416, 'YELLOW_GREEN',  turn('seg6',  'right',  30)),
    seg6:  seg('seg6', 200, 'RED_GREEN',     turn('seg7',  'right',  30)),
    seg7:  seg('seg7', 220, 'ALL_GREEN',     turn('seg8',  'left',   80)),
    seg8:  seg('seg8', 240, 'YELLOW_GREEN',  turn('seg9',  'left',   70)),
    seg9:  seg('seg9', 200, 'RED_GREEN',     turn('seg10', 'right',  80)),
    seg10: seg('seg10', 220, 'ALL_GREEN',    turn('seg11', 'right',  20)),
    seg11: seg('seg11', 200, 'YELLOW_GREEN', turn('seg12', 'left',   70)),
    seg12: seg('seg12', 200, 'RED_GREEN',    turn('seg13', 'right',  15)),
    seg13: seg('seg13', 200, 'ALL_GREEN',    turn('seg14', 'right',  15)),
    seg14: seg('seg14', 200, 'YELLOW_GREEN', turn('seg15', 'right',  15)),
    seg15: seg('seg15', 200, 'RED_GREEN',    turn('seg16', 'right',  15)),
    seg16: seg('seg16', 400, 'ALL_GREEN',    null),
  };
  const order: SegId[] = [
    'seg1', 'seg2', 'seg3', 'seg4', 'seg5', 'seg6', 'seg7', 'seg8', 'seg9', 'seg10',
    'seg11', 'seg12', 'seg13', 'seg14', 'seg15', 'seg16',
  ];
  for (const id of order) {
    const s = segments[id];
    if (s.exit) {
      const next = segments[s.exit.to];
      next.entryTan = s.exitTan;
      next.entryAngle = s.exitAngle;
      next.northHeading = s.northHeading + s.exitSign * s.exitAngle;   // accumulate orientation along the route
    }
  }
  // Trees, now that each end's tangent is known (tree.ts keeps a clear zone
  // around each intersection so none land on the adjoining road).
  for (const id of order) {
    const s = segments[id];
    s.trees = segmentTrees(s.length, s.entryTan, s.exitTan, s.scheme, LANE_WIDTH / 2);
  }
  return { segments, start: 'seg1', order };
}

// ----------------------------------------------------------------------------
// getNextRiderState — advance the Rider one frame. Pure: (RiderState, World) ->
// the next RiderState. Called explicitly before each draw; the returned state is
// what the renderer is handed.
// ----------------------------------------------------------------------------
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];
  const next = state.turn === null ? cruise(state, seg, world) : straightenStep(state, seg);
  assertInvariants(next, world);
  return next;
}

// Is the Rider close enough to the upcoming intersection to start slowing for it?
// (Only meaningful for a segment that HAS a turn; the final segment never brakes
// and is handled directly in accel/cruise.)
function nearIntersection(state: RiderState, seg: RoadSegment): boolean {
  if (!seg.exit) return true;
  return seg.length - state.along <= APPROACH_INTERSECTION_DIST;
}

// The speed a turn is taken at: a GENTLE wide arc. The Rider enters ON the inner edge
// still pointed the old way, then lets the angle-kill drift him the full lane-width to
// the FAR edge. Pick the speed so that killing the whole turn angle (rotating at
// omegaFor) sweeps exactly (width - margin) of lateral drift: a constant-speed
// constant-omega arc has radius R = v/omega and lateral drift R*(1 - cos THETA), so
//   v = omega * (width - margin) / (1 - cos THETA).
// A wide, gentle arc that USES the whole lane instead of hugging the near edge.
// (margin keeps the far end a hair inside the road.)
function turnSpeed(seg: RoadSegment): number {
  return omegaFor(seg.exitAngle) * (seg.width - STRAIGHTEN_MARGIN) / (1 - Math.cos(seg.exitAngle));
}

// Acceleration (m/press^2) PURELY from position, velocity, and distance-to-turn:
//   intersection still far -> keep accelerating at a constant rate.
//   intersection near       -> the EXACT constant deceleration that lands the
//     Rider at turn speed (0 at the route end) right at the turn point, from
//     v^2 = vEnd^2 + 2*a*d. Recomputed every press: constant-decel kinematics are
//     self-consistent, so this reproduces the same a each press while correcting
//     integration drift.
function accel(state: RiderState, seg: RoadSegment): number {
  // Far from a turn (or on the exit-less final segment): accelerate at A_ACCEL.
  // Approaching one: brake to reach the lane-filling turn speed right at the inner-edge
  // crossing (straightenStart), where the Rider commits to the next segment.
  if (!seg.exit || !nearIntersection(state, seg)) return A_ACCEL;
  const d = seg.straightenStart - state.along;
  if (d <= 1e-6) return 0;
  const vEnd = turnSpeed(seg);
  return (vEnd * vEnd - state.v * state.v) / (2 * d);
}

function cruise(state: RiderState, seg: RoadSegment, world: World): RiderState {
  let v = clamp(state.v + accel(state, seg), 0, V_MAX);

  if (!seg.exit) {   // the final segment: accelerate to the end, then the game is over
    const along = state.along + v;
    if (along >= seg.length) return { ...state, along: seg.length, v: 0 };   // reached the end -> stop
    return { ...state, along, v };
  }

  // braked to the lane-filling speed; cross the inner edge and straighten into the next
  if (nearIntersection(state, seg)) v = Math.max(v, turnSpeed(seg));   // never crawl below the lane-filling speed
  const along = state.along + v;
  if (along < seg.straightenStart) return { ...state, along, v };     // cross the inner edge -> commit to the next segment
  return enterStraighten(seg, world, v);
}

// Crossing into a turn: the moment the Rider crosses the extension of the next
// segment's INNER edge (at straightenStart on this segment) we re-express him in the
// next segment's frame and straighten out. Crossing that edge, the Rider lands ON the
// inner edge (across = sgn*hw — the right edge for a right turn), still pointed the OLD
// way (angle = -sgn*theta), and a touch BEFORE the new segment's begin line (along =
// -hw/sin(theta), negative — expected). Same physical point, so position is continuous.
function enterStraighten(seg: RoadSegment, world: World, v: number): RiderState {
  const next = world.segments[(seg.exit as { to: SegId }).to];
  const sgn = seg.exitSign, theta = seg.exitAngle, hw = seg.width / 2;
  return {
    segment: next.id,
    along: -hw / Math.sin(theta),
    across: sgn * hw,
    angle: -sgn * theta,
    v,
    turn: { angle: theta, phase: 'straightening', recenterEnd: 0 },
  };
}

// One press of straighten-out, run in two EXPLICIT, SEQUENTIAL phases carried in
// turn.phase. (Deriving the phase from |angle| each press instead caused a wiggle:
// the recenter lean raised |angle| past the threshold, which flipped the bike back
// into "still misaligned, kill the angle", which rotated it straight again — a bang-
// bang oscillation. The phase, once advanced, never reverts.)
//   (1) 'straightening' — ANGLE-KILL (urgent): rotate the heading to 0 at omegaFor,
//       holding the lane-filling speed; the bike arcs across to the far edge. v_safe
//       is the hard road-edge cap. Heading reaches 0 -> finish (if already centred) or
//       hand off to recenter.
//   (2) 'recentering' — at leisure: aim at the centre line RECENTER_DISTANCE ahead, so
//       the offset closes LINEARLY and the Rider is back at centre that far down the
//       road. Re-accelerating; resume cruising once centred (the residual lean is tiny).
function straightenStep(state: RiderState, seg: RoadSegment): RiderState {
  const hw = seg.width / 2;
  const t = state.turn as Turning;
  const omega = omegaFor(t.angle);          // per-press rotation for this turn
  const killing = t.phase === 'straightening';

  // angle-kill steers straight to 0; recenter aims at the centre line RECENTER_DISTANCE
  // ahead — heading = -across/(remaining distance), so the offset closes linearly.
  const aim = killing ? 0 : -state.across / (t.recenterEnd - state.along);
  const dHeading = clamp(aim - state.angle, -omega, omega);
  const angle = state.angle + dHeading;

  // hold the lane-filling speed through the angle-kill (no accelerating mid-corner);
  // re-accelerate while recentring. v_safe is the hard road-edge cap: nulling the
  // CURRENT heading a at radius R = v/omega drifts R*(1 - cos a) = v*(1 - cos a)/omega
  // toward the edge it points at, so cap v to keep that inside `room`. At angle-kill
  // entry this EXACTLY equals turnSpeed, so it just holds the calibrated arc; it only
  // bites if `across` drifts unexpectedly (the recenter lean is too small to bind).
  let v = killing ? state.v : state.v + A_ACCEL;
  const a = state.angle;
  if (Math.abs(a) > 1e-3) {
    const room = Math.max(0, hw - STRAIGHTEN_MARGIN - state.across * Math.sign(a));
    v = Math.min(v, omega * room / (1 - Math.cos(a)));
  }
  v = clamp(v, 0, V_MAX);

  const mid = state.angle + dHeading / 2;
  const along = state.along + v * Math.cos(mid);
  const across = state.across + v * Math.sin(mid);

  const aligned = Math.abs(angle) < ALIGN_EPS, centred = Math.abs(across) < CENTER_EPS;
  if (killing) {
    if (aligned && centred) return { segment: seg.id, along, across: 0, angle: 0, v, turn: null };        // straightened in one go
    if (aligned) return { segment: seg.id, along, across, angle, v, turn: { ...t, phase: 'recentering', recenterEnd: along + RECENTER_DISTANCE } };
    return { segment: seg.id, along, across, angle, v, turn: t };
  }
  // recentring: done once back at the centre line (the residual lean is tiny)
  if (centred) return { segment: seg.id, along, across: 0, angle: 0, v, turn: null };
  return { segment: seg.id, along, across, angle, v, turn: t };
}

// ----------------------------------------------------------------------------
// Invariants. The Rider may sit BEFORE a segment's start (negative along — he crosses
// into a turn at the inner edge, just shy of the begin line); this pins down "how far
// before is reasonable", plus the usual finite and bounded checks.
// ----------------------------------------------------------------------------
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
  const entryFloor = seg.entryAngle > 0 ? -(seg.width / 2) / Math.sin(seg.entryAngle) : 0;
  assert(s.along >= entryFloor - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + 1e-6, `along not past end (${s.along})`);
  assert(Math.abs(s.across) <= seg.width / 2 + 1, `across bounded (${s.across})`);
  if (s.turn === null) {
    assert(Math.abs(s.across) < 1e-6 && Math.abs(s.angle) < 1e-6, 'cruising => centred and aligned');
  }
}
