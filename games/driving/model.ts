// =============================================================================
// model — the pure, relational driving model. No canvas, no world coordinates,
// and (now) no absolute directions: a segment relates to its neighbour only by
// a turn ANGLE. Node-testable (test/test_model.ts).
//
// HOW THE CAR MOVES, FRAME BY FRAME
//
// Position is relative to the CURRENT segment: along (progress), across
// (lateral offset, + = right), angle (heading relative to the segment), and v
// (speed along the path, m/press).
//
// Cruising:  across = 0, angle = 0; each press advances `along` by v, and v
//            changes by accel() — a pure function of (along, v, can-the-driver-
//            see-the-intersection-yet). Out of sight: constant acceleration.
//            In sight: the exact constant deceleration that brings the car to
//            turn speed right at the corner (recomputed each press, so it self-
//            corrects discretisation drift). See accel() / cruise().
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
// by THETA about the shared corner. Continuous; the car never jumps.
// =============================================================================

export const DPHI = 0.05;         // heading turned per press in a 90deg turn (rad)
export const V_BASE = 1.2;        // the car's speed at the very start of the drive (m/press)
export const A_ACCEL = 0.03;      // constant acceleration while the intersection is out of sight (m/press^2)
export const SIGHT = 180;         // how far ahead the adult elephant (= the intersection) becomes visible (m)
const ELEPHANT_AHEAD = 20;        // the adult elephant sits this far past a segment's end (matches elephantRow)

const QUARTER = Math.PI / 2;
const omegaFor = (theta: number): number => DPHI * theta / QUARTER;  // turn rate scales with angle

// ----------------------------------------------------------------------------
// World — a relational chain of segments. Scalars only; never coordinates.
// ----------------------------------------------------------------------------
export type SegId = string;
export type TurnDir = 'left' | 'right';
export type Scheme = 'ALL_GREEN' | 'YELLOW_GREEN' | 'RED_GREEN';
export interface TreeLocal { side: 'left' | 'right'; along: number; offset: number; color: string; height: number }
export interface CritterLocal { along: number; across: number; emoji: string; height: number; faceRight: boolean }

const GREEN = '#2f7a30', YELLOW = '#cf9a18', RED = '#b23a2a';
const TREE_H = 5;   // base tree height (metres); green trees are half this

export interface RoadSegment {
  id: SegId;
  length: number;
  width: number;
  scheme: Scheme;                // visual theme; drives the tree colours
  trees: TreeLocal[];
  critters: CritterLocal[];      // roadside, along the segment (cows/pigs)
  exitCritters: CritterLocal[];  // at the exit intersection (elephants); shared with the next segment
  exit: { dir: TurnDir; to: SegId; radius: number; angle: number } | null;
  // derived relational scalars (filled by buildWorld)
  exitR: number;        // exit turn radius (0 if none)
  exitSign: number;     // +1 right, -1 left, 0 none
  exitAngle: number;    // turn angle THETA (0 if none)
  exitTan: number;      // R * tan(THETA/2): how far before the corner the turn starts
  entryR: number;       // radius of the turn that feeds this segment
  entryTan: number;     // where this segment's straight begins (past its start)
  arcStart: number;     // length - exitTan
}

export interface World {
  segments: Record<SegId, RoadSegment>;
  start: SegId;
  order: SegId[];
}

// ----------------------------------------------------------------------------
// Car state. `turn` is null while cruising; a small descriptor while turning.
// ----------------------------------------------------------------------------
export interface Turning { sgn: number; r: number; angle: number; phase: 'exiting' | 'entering'; toSeg: SegId }
export interface CarState {
  segment: SegId;
  along: number;
  across: number;
  angle: number;
  v: number;          // speed along the path (m/press)
  turn: Turning | null;
}

export function initialState(world: World): CarState {
  return { segment: world.start, along: 0, across: 0, angle: 0, v: V_BASE, turn: null };
}

const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);

export function buildWorld(): World {
  const LANE = 4;   // one-lane road ~ two car widths
  const R = 2;      // turn radius
  const DEG = Math.PI / 180;

  const seg = (id: SegId, length: number, scheme: Scheme,
               exit: RoadSegment['exit']): RoadSegment => {
    const tan = exit ? exit.radius * Math.tan(exit.angle / 2) : 0;
    return {
      id, length, width: LANE, scheme,
      trees: [],   // filled below, once entry/exit tangents are known
      critters: critterRow(length, LANE / 2),
      exitCritters: elephantRow(length, exit),
      exit,
      exitR: exit ? exit.radius : 0,
      exitSign: exit ? signOf(exit.dir) : 0,
      exitAngle: exit ? exit.angle : 0,
      exitTan: tan,
      entryR: 0, entryTan: 0,
      arcStart: length - tan,
    };
  };
  const turn = (to: SegId, dir: TurnDir, deg: number): RoadSegment['exit'] =>
    ({ dir, to, radius: R, angle: deg * DEG });

  // route is checked non-self-intersecting by test/test_model.ts (no loops).
  const segments: Record<SegId, RoadSegment> = {
    seg1:  seg('seg1', 200, 'ALL_GREEN',    turn('seg2',  'right',  90)),
    seg2:  seg('seg2', 220, 'YELLOW_GREEN', turn('seg3',  'left',  120)),
    seg3:  seg('seg3', 416, 'RED_GREEN',    turn('seg4',  'right',  60)),   // the longest straight: most aggressive
    seg4:  seg('seg4', 200, 'ALL_GREEN',    turn('seg5',  'right',  30)),
    seg5:  seg('seg5', 220, 'YELLOW_GREEN', turn('seg6',  'left',  120)),
    seg6:  seg('seg6', 240, 'RED_GREEN',    turn('seg7',  'left',   60)),
    seg7:  seg('seg7', 200, 'ALL_GREEN',    turn('seg8',  'right',  90)),
    seg8:  seg('seg8', 220, 'YELLOW_GREEN', turn('seg9',  'right',  60)),
    seg9:  seg('seg9', 200, 'RED_GREEN',    turn('seg10', 'left',  120)),
    seg10: seg('seg10', 200, 'ALL_GREEN',   null),
  };
  const order: SegId[] = [
    'seg1', 'seg2', 'seg3', 'seg4', 'seg5', 'seg6', 'seg7', 'seg8', 'seg9', 'seg10',
  ];
  for (const id of order) {
    const s = segments[id];
    if (s.exit) {
      const next = segments[s.exit.to];
      next.entryR = s.exit.radius;
      next.entryTan = s.exitTan;
    }
  }
  // Trees, now that each end's tangent is known. A turn intrudes `tan` into the
  // straight; we keep that clear PLUS a clearance so a tree never lands on the
  // adjoining road (and none sit right at a segment's start/end).
  for (const id of order) {
    const s = segments[id];
    const startAlong = s.entryTan + TREE_CLEARANCE;
    const endAlong = s.length - s.exitTan - TREE_CLEARANCE;
    s.trees = treeRow(startAlong, endAlong, s.scheme);
  }
  return { segments, start: 'seg1', order };
}

const TREE_CLEARANCE = 6;   // metres of clear ground near an intersection (beyond the turn's reach)

function treeRow(startAlong: number, endAlong: number, scheme: Scheme): TreeLocal[] {
  const trees: TreeLocal[] = [];
  let k = 0;
  for (let along = startAlong; along <= endAlong; along += 6, k++) {
    const color = treeColor(scheme, k);   // alternates along the segment
    const height = color === GREEN ? TREE_H / 2 : TREE_H;
    trees.push({ side: 'left', along, offset: 1.5, color, height });
    trees.push({ side: 'right', along, offset: 1.5, color, height });
  }
  return trees;
}
function treeColor(scheme: Scheme, k: number): string {
  if (scheme === 'ALL_GREEN') return GREEN;
  const accent = scheme === 'YELLOW_GREEN' ? YELLOW : RED;
  return k % 2 === 0 ? GREEN : accent;
}

// Four cows on the left, four pigs on the right, clustered halfway down the
// segment and set further back than the trees. (Full-body emoji.)
function critterRow(length: number, hw: number): CritterLocal[] {
  const out: CritterLocal[] = [];
  const mid = length / 2;
  const edge = hw + 10;   // further out than the trees (offset 1.5)
  for (const d of [-6, -2, 2, 6]) {
    out.push({ along: mid + d, across: -edge, emoji: '🐄', height: 1.4, faceRight: true });
    out.push({ along: mid + d, across:  edge, emoji: '🐖', height: 1.1, faceRight: false });
  }
  return out;
}

// Beyond the upcoming intersection: an adult elephant straight ahead, and its
// BABY (cow-sized) just past it and a bit to the side OPPOSITE the upcoming
// turn. Both ~twice as far out as the cows/pigs.
function elephantRow(length: number, exit: RoadSegment['exit']): CritterLocal[] {
  if (!exit) return [];
  const corner = length + ELEPHANT_AHEAD;
  return [
    { along: corner,     across: 0,                         emoji: '🐘', height: 2.8, faceRight: false },
    { along: corner + 6, across: -signOf(exit.dir) * 14,    emoji: '🐘', height: 1.4, faceRight: false },
  ];
}

// ----------------------------------------------------------------------------
// advanceCar — one forward press.
// ----------------------------------------------------------------------------
export function advanceCar(state: CarState, world: World): CarState {
  const seg = world.segments[state.segment];
  const next = state.turn === null ? cruise(state, seg, world) : turnStep(state, seg, world);
  assertInvariants(next, world);
  return next;
}

// Can the driver see the upcoming intersection yet? Yes once the adult elephant
// beyond it is within SIGHT. The route's final segment has no intersection — its
// end is always "in view" (the car simply coasts to a stop there).
function sees(state: CarState, seg: RoadSegment): boolean {
  if (!seg.exit) return true;
  return seg.length + ELEPHANT_AHEAD - state.along <= SIGHT;
}

// the speed at which a turn is taken (its fixed per-press creep) — the speed the
// approach must decelerate to so motion is continuous into the turn.
const turnSpeed = (seg: RoadSegment): number => seg.exitR * omegaFor(seg.exitAngle);

// Acceleration (m/press^2) PURELY from position, velocity, and visibility:
//   intersection out of sight -> keep accelerating at a constant rate.
//   intersection in view       -> the EXACT constant deceleration that lands the
//     car at turn speed (0 at the route end) right at the turn point, from
//     v^2 = vEnd^2 + 2*a*d. Recomputed every press: constant-decel kinematics are
//     self-consistent, so this reproduces the same a each press while correcting
//     integration drift.
function accel(state: CarState, seg: RoadSegment): number {
  if (!sees(state, seg)) return A_ACCEL;
  const turnPoint = seg.exit ? seg.arcStart : seg.length;
  const vEnd = seg.exit ? turnSpeed(seg) : 0;
  const d = turnPoint - state.along;
  if (d <= 1e-6) return 0;
  return (vEnd * vEnd - state.v * state.v) / (2 * d);
}

function cruise(state: CarState, seg: RoadSegment, world: World): CarState {
  let v = Math.max(0, state.v + accel(state, seg));

  if (!seg.exit) {   // route end: coast to a stop at the far end
    const along = state.along + v;
    if (along >= seg.length || v < 1e-2) return { ...state, along: seg.length, v: 0 };
    return { ...state, along, v };
  }

  const vEnd = turnSpeed(seg);
  if (sees(state, seg)) v = Math.max(v, vEnd);   // while braking for the turn, never crawl below turn speed
  const along = state.along + v;
  if (along < seg.arcStart) return { ...state, along, v };

  const turn: Turning = {
    sgn: seg.exitSign, r: seg.exitR, angle: seg.exitAngle, phase: 'exiting', toSeg: seg.exit.to,
  };
  return turnStep({ segment: seg.id, along: seg.arcStart, across: 0, angle: 0, v: vEnd, turn }, seg, world);
}

function turnStep(state: CarState, seg: RoadSegment, world: World): CarState {
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

// Re-express the car in the next segment's frame: a rotation by THETA about the
// shared corner (A's far end = B's start). Reduces to the simple swap at 90deg.
function handoff(along: number, across: number, angle: number,
                 from: RoadSegment, world: World, t: Turning): CarState {
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

// ----------------------------------------------------------------------------
// Invariants. We ALLOW the car past a segment's end (nosing into the turn) and
// before its start (entering); these pin down "how far is reasonable".
// ----------------------------------------------------------------------------
function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error('invariant violated: ' + msg);
}
export function assertInvariants(s: CarState, world: World): void {
  const seg = world.segments[s.segment];
  assert(Number.isFinite(s.along) && Number.isFinite(s.across) && Number.isFinite(s.angle),
         `finite (${s.along},${s.across},${s.angle})`);
  assert(Number.isFinite(s.v) && s.v >= -1e-9 && s.v <= 6, `v sane (${s.v})`);
  assert(Math.abs(s.angle) <= QUARTER + 1e-6, `|angle| <= 90deg (${s.angle})`);
  assert(s.along >= -seg.entryR - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + seg.exitR + 1e-6, `along not far past end (${s.along})`);
  const lateralRoom = seg.width / 2 + Math.max(seg.entryR, seg.exitR) + 1;
  assert(Math.abs(s.across) <= lateralRoom, `across bounded (${s.across})`);
  if (s.turn === null) {
    assert(Math.abs(s.across) < 1e-6 && Math.abs(s.angle) < 1e-6, 'cruising => centred and aligned');
  }
}
