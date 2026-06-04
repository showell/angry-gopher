// =============================================================================
// model — the pure, relational driving model. No canvas, no world coordinates,
// and (now) no absolute directions: a segment relates to its neighbour only by
// a turn ANGLE. Node-testable (test/test_model.ts).
//
// HOW THE CAR MOVES, FRAME BY FRAME
//
// Position is relative to the CURRENT segment: along (progress), across
// (lateral offset, + = right), angle (heading relative to the segment).
//
// Cruising:  across = 0, angle = 0; each press advances `along`, decelerating
//            into the turn.
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

export const STEP = 1.2;          // metres advanced per press while cruising
export const DPHI = 0.05;         // heading turned per press in a 90deg turn (rad)
export const BRAKE_ZONE = 8;      // metres before a turn over which we decelerate

const QUARTER = Math.PI / 2;
const omegaFor = (theta: number): number => DPHI * theta / QUARTER;  // turn rate scales with angle

// ----------------------------------------------------------------------------
// World — a relational chain of segments. Scalars only; never coordinates.
// ----------------------------------------------------------------------------
export type SegId = string;
export type TurnDir = 'left' | 'right';
export interface TreeLocal { side: 'left' | 'right'; along: number; offset: number }

export interface RoadSegment {
  id: SegId;
  length: number;
  width: number;
  foliage: string;      // tree-top colour; every tree on the segment shares it
  trees: TreeLocal[];
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
  turn: Turning | null;
}

export function initialState(world: World): CarState {
  return { segment: world.start, along: 0, across: 0, angle: 0, turn: null };
}

const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);

export function buildWorld(): World {
  const LANE = 4;   // one-lane road ~ two car widths
  const R = 2;      // turn radius
  const DEG = Math.PI / 180;
  const GREEN = '#2f7a30', RED = '#b23a2a', GOLD = '#cf9a18';

  const seg = (id: SegId, length: number, foliage: string,
               exit: RoadSegment['exit']): RoadSegment => {
    const tan = exit ? exit.radius * Math.tan(exit.angle / 2) : 0;
    return {
      id, length, width: LANE, foliage, trees: treeRow(length), exit,
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
    seg1:  seg('seg1',  50, GREEN, turn('seg2',  'right',  90)),
    seg2:  seg('seg2',  55, GOLD,  turn('seg3',  'left',  120)),
    seg3:  seg('seg3',  80, RED,   turn('seg4',  'right',  60)),
    seg4:  seg('seg4',  50, GREEN, turn('seg5',  'right',  30)),
    seg5:  seg('seg5',  55, GOLD,  turn('seg6',  'left',  120)),
    seg6:  seg('seg6',  60, RED,   turn('seg7',  'left',   60)),
    seg7:  seg('seg7',  50, GREEN, turn('seg8',  'right',  90)),
    seg8:  seg('seg8',  55, GOLD,  turn('seg9',  'right',  60)),
    seg9:  seg('seg9',  50, RED,   turn('seg10', 'left',  120)),
    seg10: seg('seg10', 50, GREEN, null),
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
  return { segments, start: 'seg1', order };
}

function treeRow(length: number): TreeLocal[] {
  const trees: TreeLocal[] = [];
  for (let along = 4; along <= length - 4; along += 6) {
    trees.push({ side: 'left', along, offset: 1.5 });
    trees.push({ side: 'right', along, offset: 1.5 });
  }
  return trees;
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

function cruise(state: CarState, seg: RoadSegment, world: World): CarState {
  const target = seg.exit ? seg.arcStart : seg.length;
  const remaining = target - state.along;
  if (remaining > 1e-6) {
    return { ...state, along: Math.min(state.along + cruiseStep(remaining, seg), target) };
  }
  if (!seg.exit) return state;   // parked at the end of the route
  const turn: Turning = {
    sgn: seg.exitSign, r: seg.exitR, angle: seg.exitAngle, phase: 'exiting', toSeg: seg.exit.to,
  };
  return turnStep({ segment: seg.id, along: seg.arcStart, across: 0, angle: 0, turn }, seg, world);
}

function cruiseStep(remaining: number, seg: RoadSegment): number {
  const creep = seg.exitR > 0 ? seg.exitR * omegaFor(seg.exitAngle) : STEP;
  if (remaining >= BRAKE_ZONE) return STEP;
  return creep + (STEP - creep) * (remaining / BRAKE_ZONE);
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
    if (angle * t.sgn < t.angle / 2) return { segment: seg.id, along, across, angle, turn: t };
    return handoff(along, across, angle, seg, world, t);   // arc midpoint -> advance the segment
  }
  // entering: turn until aligned with the new segment, then resume cruising
  if (angle * t.sgn < 0) return { segment: seg.id, along, across, angle, turn: t };
  return { segment: seg.id, along: seg.entryTan, across: 0, angle: 0, turn: null };
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
  assert(Math.abs(s.angle) <= QUARTER + 1e-6, `|angle| <= 90deg (${s.angle})`);
  assert(s.along >= -seg.entryR - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + seg.exitR + 1e-6, `along not far past end (${s.along})`);
  const lateralRoom = seg.width / 2 + Math.max(seg.entryR, seg.exitR) + 1;
  assert(Math.abs(s.across) <= lateralRoom, `across bounded (${s.across})`);
  if (s.turn === null) {
    assert(Math.abs(s.across) < 1e-6 && Math.abs(s.angle) < 1e-6, 'cruising => centred and aligned');
  }
}
