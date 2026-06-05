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
// Turning (no precomputed arc): each press rotates the heading by `omega` and
// inches forward `ds = R * omega` — forward and rotation IN SYNC, tracing a
// circle of radius R. We integrate in the segment frame:
//   along  += ds * cos(angle);  across += ds * sin(angle);  angle += omega.
// For a turn of total angle THETA we rotate omega = DPHI * THETA / (pi/2) per
// press — i.e. a 60deg turn rotates 2/3 as fast as a 90deg turn, so every turn
// takes the same number of presses. The straight ends a tangent length
// t = R * tan(THETA/2) before the corner; the next segment's straight begins
// the same t past its start.
//
// Handoff: at the arc midpoint (THETA/2) we advance the current segment A->B,
// re-expressing the very same (along, across, angle) in B's frame — a rotation
// by THETA about the shared corner. Continuous; the Rider never jumps.
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
const TURN_RADIUS = 2;                   // radius of every corner

// the Rider starts slowing once the next intersection is within this distance
const APPROACH_INTERSECTION_DIST = 160;

// ---- motion (per-press, not metres) ----
export const DPHI = 0.10;     // heading turned per press in a 90deg turn (rad); sets turn speed AND spin rate
export const V_BASE = 1.2;    // the Rider's speed at the very start of the drive (m/press)
export const A_ACCEL = 0.03;  // constant acceleration while the intersection is still far off (m/press^2)
const V_MAX = 6;              // top speed (m/press) — the bike never accelerates past this

const QUARTER = Math.PI / 2;
const omegaFor = (theta: number): number => DPHI * theta / QUARTER;  // turn rate scales with angle

// ---- straighten-out: easy turns (theta <= EASY_TURN_MAX) skip the rigid arc ----
// The bike (a point) crosses into the new segment at the tangent point and then
// straightens out, instead of tracing an arc — see enterStraighten/straightenStep.
const EASY_TURN_MAX = 60 * Math.PI / 180;   // turns up to this gentle get straighten-out, not an arc
export const STRAIGHTEN_OMEGA = 0.25;       // max heading change per press while straightening (rad): the "flick" rate
const STRAIGHTEN_MARGIN = 0.3;              // keep the drift bulge at least this far inside the road edge (m)
const RECENTER_MAX_ANGLE = 0.12;            // gentlest heading used to ease back to centre once aligned (rad)
const RECENTER_GAIN = 0.08;                 // recenter aim angle = -RECENTER_GAIN * across (per m)
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
  exitR: number;        // exit turn radius (0 if none)
  exitSign: number;     // +1 right, -1 left, 0 none
  exitAngle: number;    // turn angle THETA (0 if none)
  exitTan: number;      // R * tan(THETA/2): how far before the corner the turn starts
  entryR: number;       // radius of the turn that feeds this segment
  entryTan: number;     // where this segment's straight begins (past its start)
  arcStart: number;     // length - exitTan
  northHeading: number; // heading relative to north (seg1 = 0), radians — the one absolute orientation we keep
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
export interface Turning { sgn: number; r: number; angle: number; phase: 'exiting' | 'entering' | 'straightening'; toSeg: SegId }
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
// faces, not where it is. Continuous across handoffs (segment base + angle).
export function riderHeading(state: RiderState, world: World): number {
  return world.segments[state.segment].northHeading + state.angle;
}

const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);
const segNumber = (id: SegId): number => Number(id.slice(3));   // "seg12" -> 12
const clamp = (x: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, x));

export function buildWorld(): World {
  const DEG = Math.PI / 180;

  const seg = (id: SegId, length: number, scheme: Scheme,
               exit: RoadSegment['exit']): RoadSegment => {
    const tan = exit ? exit.radius * Math.tan(exit.angle / 2) : 0;
    return {
      id, length, width: LANE_WIDTH, scheme,
      trees: [],   // filled below, once entry/exit tangents are known
      critters: segmentCritters(length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
      exitCritters: exit ? intersectionCritters(length, signOf(exit.dir), segNumber(id)) : [],
      exit,
      exitR: exit ? exit.radius : 0,
      exitSign: exit ? signOf(exit.dir) : 0,
      exitAngle: exit ? exit.angle : 0,
      exitTan: tan,
      entryR: 0, entryTan: 0,
      arcStart: length - tan,
      northHeading: 0,
    };
  };
  const turn = (to: SegId, dir: TurnDir, deg: number): RoadSegment['exit'] =>
    ({ dir, to, radius: TURN_RADIUS, angle: deg * DEG });

  // route is checked non-self-intersecting by test/test_model.ts (no loops).
  const segments: Record<SegId, RoadSegment> = {
    seg1:  seg('seg1', 300, 'ALL_GREEN',    turn('seg2',  'right',  50)),
    seg2:  seg('seg2', 320, 'YELLOW_GREEN', turn('seg3',  'left',  80)),
    seg3:  seg('seg3', 416, 'RED_GREEN',    turn('seg4',  'right',  60)),   // the longest straight: most aggressive
    seg4:  seg('seg4', 200, 'ALL_GREEN',    turn('seg5',  'right',  30)),
    seg5:  seg('seg5', 220, 'YELLOW_GREEN', turn('seg6',  'left',  120)),
    seg6:  seg('seg6', 240, 'RED_GREEN',    turn('seg7',  'left',   60)),
    seg7:  seg('seg7', 200, 'ALL_GREEN',    turn('seg8',  'right',  90)),
    seg8:  seg('seg8', 220, 'YELLOW_GREEN', turn('seg9',  'right',  60)),
    seg9:  seg('seg9', 200, 'RED_GREEN',    turn('seg10', 'left',  120)),
    seg10: seg('seg10', 200, 'ALL_GREEN',   turn('seg11', 'right',  15)),
    seg11: seg('seg11', 200, 'YELLOW_GREEN', turn('seg12', 'right', 15)),
    seg12: seg('seg12', 200, 'RED_GREEN',    turn('seg13', 'right', 15)),
    seg13: seg('seg13', 200, 'ALL_GREEN',    turn('seg14', 'right', 15)),
    seg14: seg('seg14', 400, 'YELLOW_GREEN', null),   // the long final straight: accelerate, never brake, then end
  };
  const order: SegId[] = [
    'seg1', 'seg2', 'seg3', 'seg4', 'seg5', 'seg6', 'seg7', 'seg8', 'seg9', 'seg10',
    'seg11', 'seg12', 'seg13', 'seg14',
  ];
  for (const id of order) {
    const s = segments[id];
    if (s.exit) {
      const next = segments[s.exit.to];
      next.entryR = s.exit.radius;
      next.entryTan = s.exitTan;
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
  const t = state.turn;
  const next = t === null ? cruise(state, seg, world)
             : t.phase === 'straightening' ? straightenStep(state, seg)
             : turnStep(state, seg, world);
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

// the speed at which a turn is taken (its fixed per-press creep) — the speed the
// approach must decelerate to so motion is continuous into the turn.
const turnSpeed = (seg: RoadSegment): number => seg.exitR * omegaFor(seg.exitAngle);
const isEasy = (seg: RoadSegment): boolean => seg.exit !== null && seg.exitAngle <= EASY_TURN_MAX;

// Acceleration (m/press^2) PURELY from position, velocity, and distance-to-turn:
//   intersection still far -> keep accelerating at a constant rate.
//   intersection near       -> the EXACT constant deceleration that lands the
//     Rider at turn speed (0 at the route end) right at the turn point, from
//     v^2 = vEnd^2 + 2*a*d. Recomputed every press: constant-decel kinematics are
//     self-consistent, so this reproduces the same a each press while correcting
//     integration drift.
function accel(state: RiderState, seg: RoadSegment): number {
  // Accelerate at the constant rate when: there's no turn (final segment), the
  // turn is EASY (straighten-out does its own braking, so we carry speed in), or
  // the turn is still far off. Otherwise brake to the (sharp) turn's creep speed.
  if (!seg.exit || isEasy(seg) || !nearIntersection(state, seg)) return A_ACCEL;
  const d = seg.arcStart - state.along;
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

  if (isEasy(seg)) {   // carry speed to the tangent point, then snap in and straighten out
    const along = state.along + v;
    if (along < seg.arcStart) return { ...state, along, v };
    return enterStraighten(seg, world, v);
  }

  const vEnd = turnSpeed(seg);
  if (nearIntersection(state, seg)) v = Math.max(v, vEnd);   // while braking for the turn, never crawl below turn speed
  const along = state.along + v;
  if (along < seg.arcStart) return { ...state, along, v };

  const turn: Turning = {
    sgn: seg.exitSign, r: seg.exitR, angle: seg.exitAngle, phase: 'exiting', toSeg: seg.exit.to,
  };
  return turnStep({ segment: seg.id, along: seg.arcStart, across: 0, angle: 0, v: vEnd, turn }, seg, world);
}

function turnStep(state: RiderState, seg: RoadSegment, world: World): RiderState {
  const t = state.turn as Turning;
  const omega = omegaFor(t.angle);
  const dHeading = t.sgn * omega;
  const ds = t.r * omega;                  // forward IN SYNC with rotation
  const mid = state.angle + dHeading / 2;
  const along = state.along + ds * Math.cos(mid);
  const across = state.across + ds * Math.sin(mid);
  const angle = state.angle + dHeading;

  if (t.phase === 'exiting') {
    if (angle * t.sgn < t.angle / 2) return { segment: seg.id, along, across, angle, v: ds, turn: t };
    return handoff(along, across, angle, seg, world, t);   // arc midpoint -> advance the segment
  }
  // entering: turn until aligned with the new segment, then resume cruising
  if (angle * t.sgn < 0) return { segment: seg.id, along, across, angle, v: ds, turn: t };
  // leave the turn at the turn's OWN speed and accelerate from there (no jump to V_BASE)
  return { segment: seg.id, along: seg.entryTan, across: 0, angle: 0, v: ds, turn: null };
}

// Re-express the Rider in the next segment's frame: a rotation by THETA about the
// shared corner (A's far end = B's start). Reduces to the simple swap at 90deg.
function handoff(along: number, across: number, angle: number,
                 from: RoadSegment, world: World, t: Turning): RiderState {
  const L = from.length, theta = t.angle, sgn = t.sgn;
  const dA = along - L, dX = across;
  const cosB = Math.cos(theta), sinB = sgn * Math.sin(theta);   // rotate by sgn*THETA
  const next = world.segments[t.toSeg];
  return {
    segment: next.id,
    along: dA * cosB + dX * sinB,
    across: -dA * sinB + dX * cosB,
    angle: angle - sgn * theta,
    v: next.entryR * omegaFor(theta),
    turn: { sgn, r: next.entryR, angle: theta, phase: 'entering', toSeg: next.id },
  };
}

// EASY TURN: instead of arcing, snap into the next segment's frame at the tangent
// point and straighten out. The entry (derived from that point): on the new road
// but still pointed the OLD way (angle = -sgn*theta), offset to the inside
// (across = sgn*R*(1-cos theta)), a touch before the segment's start. It's the
// same physical point, so position is continuous (no jump).
function enterStraighten(seg: RoadSegment, world: World, v: number): RiderState {
  const next = world.segments[(seg.exit as { to: SegId }).to];
  const sgn = seg.exitSign, theta = seg.exitAngle, R = seg.exitR;
  return {
    segment: next.id,
    along: -R * Math.tan(theta / 2) * Math.cos(theta),
    across: sgn * R * (1 - Math.cos(theta)),
    angle: -sgn * theta,
    v,
    turn: { sgn, r: R, angle: theta, phase: 'straightening', toSeg: next.id },
  };
}

// One press of straighten-out, on the segment we've just entered. Two priorities:
//   (1) ANGLE first (urgent): rotate toward 0 at the flick rate, letting the bike
//       drift across the centre line. Brake — instantly, the bike's only road-
//       safety lever — just enough that the drift bulge stays on the road.
//   (2) once aligned, RECENTER at leisure: a gentle opposite lean back toward the
//       centre line, giving up no speed. Overshooting centre is fine; the road
//       edge is the ONLY hard limit. Resume cruising once aligned AND centred.
function straightenStep(state: RiderState, seg: RoadSegment): RiderState {
  const hw = seg.width / 2;
  const aligned = Math.abs(state.angle) < ALIGN_EPS;

  // steer straight while the angle is still wrong; then a gentle recentre lean.
  const aim = aligned ? clamp(-RECENTER_GAIN * state.across, -RECENTER_MAX_ANGLE, RECENTER_MAX_ANGLE) : 0;
  const dHeading = clamp(aim - state.angle, -STRAIGHTEN_OMEGA, STRAIGHTEN_OMEGA);
  const angle = state.angle + dHeading;

  // nulling the CURRENT heading will drift ~ v*a^2/(2*omega) toward the edge it
  // points at; cap v so that drift (from here) stays inside the road. Use the
  // pre-steer angle — it's what drives this frame's drift — so the cap is honest.
  let v = state.v + A_ACCEL;
  const a = state.angle;
  if (Math.abs(a) > 1e-3) {
    const room = Math.max(0, hw - STRAIGHTEN_MARGIN - state.across * Math.sign(a));
    v = Math.min(v, 2 * STRAIGHTEN_OMEGA * room / (a * a));
  }
  v = clamp(v, 0, V_MAX);

  const mid = state.angle + dHeading / 2;
  const along = state.along + v * Math.cos(mid);
  const across = state.across + v * Math.sin(mid);

  if (Math.abs(angle) < ALIGN_EPS && Math.abs(across) < CENTER_EPS) {
    return { segment: seg.id, along, across: 0, angle: 0, v, turn: null };   // straightened — resume cruise
  }
  return { segment: seg.id, along, across, angle, v, turn: state.turn };
}

// ----------------------------------------------------------------------------
// Invariants. We ALLOW the Rider past a segment's end (nosing into the turn) and
// before its start (entering); these pin down "how far is reasonable".
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
  assert(s.along >= -seg.entryR - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + seg.exitR + 1e-6, `along not far past end (${s.along})`);
  const lateralRoom = seg.width / 2 + Math.max(seg.entryR, seg.exitR) + 1;
  assert(Math.abs(s.across) <= lateralRoom, `across bounded (${s.across})`);
  if (s.turn === null) {
    assert(Math.abs(s.across) < 1e-6 && Math.abs(s.angle) < 1e-6, 'cruising => centred and aligned');
  }
}
