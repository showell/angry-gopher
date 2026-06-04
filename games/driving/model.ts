// =============================================================================
// model — the pure, relational driving model. No canvas, no world coordinates.
// Node-testable (test/test_model.ts).
//
// HOW THE CAR MOVES, FRAME BY FRAME
//
// The car's position is always expressed relative to its CURRENT segment:
//   along  : progress down the segment (metres from its start)
//   across : lateral offset from the centreline (+ = right of travel)
//   angle  : heading relative to the segment direction (+ = clockwise)
//
// Cruising:  across = 0, angle = 0; each press advances `along` by a step.
//            The step DECELERATES as we approach the intersection.
//
// Turning (the quintessential problem): we do NOT precompute an arc. Each press
// is one kinematic increment — rotate the heading a little (dHeading) and inch
// forward a matching amount (ds = R * |dHeading|). Forward motion and rotation
// stay IN SYNC, so the car traces a circle of radius R. We integrate
//   along  += ds * cos(angle)      (forward component, in the segment frame)
//   across += ds * sin(angle)      (rightward component)
//   angle  += dHeading
// A right turn is clockwise (dHeading > 0); a left turn counter-clockwise.
//
// Handoff: a turn spans two segments. At the arc midpoint we advance the
// CURRENT segment from A to B — re-expressing the very same (along, across,
// angle) in B's frame. Because A and B are perpendicular and meet at the
// corner, that is a tidy coordinate transform; the car does not jump.
// =============================================================================
import type { Cardinal } from './types.ts';

export const STEP = 1.2;          // metres advanced per press while cruising
export const DPHI = 0.05;         // radians the heading turns per press in a turn (~2.9 deg)
export const BRAKE_ZONE = 8;      // metres before the turn over which we decelerate
const HANDOFF = Math.PI / 4;      // hand the current segment over at the arc midpoint

// ----------------------------------------------------------------------------
// World — a relational chain of segments. Scalars only (lengths, radii); never
// world coordinates. advanceCar reads only these.
// ----------------------------------------------------------------------------
export type SegId = string;
export type TurnDir = 'left' | 'right';
export interface TreeLocal { side: 'left' | 'right'; along: number; offset: number }

export interface RoadSegment {
  id: SegId;
  dir: Cardinal;
  length: number;
  width: number;
  trees: TreeLocal[];
  exit: { dir: TurnDir; to: SegId; radius: number } | null;
  // derived relational scalars (filled by buildWorld)
  exitR: number;        // exit turn radius (0 if none)
  exitSign: number;     // +1 right, -1 left, 0 none
  entryR: number;       // radius of the turn that feeds this segment (0 if none)
  arcStart: number;     // length - exitR (where the exit turn begins)
}

export interface World {
  segments: Record<SegId, RoadSegment>;
  start: SegId;
  order: SegId[];
}

// ----------------------------------------------------------------------------
// Car state. `turn` is null while cruising; a small descriptor while turning.
// ----------------------------------------------------------------------------
export interface Turning { sgn: number; r: number; phase: 'exiting' | 'entering'; toSeg: SegId }
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
  const R = 2;      // turn radius (fits the square intersection)
  const seg = (id: SegId, dir: Cardinal, length: number,
               exit: RoadSegment['exit']): RoadSegment => ({
    id, dir, length, width: LANE, trees: treeRow(length),
    exit,
    exitR: exit ? exit.radius : 0,
    exitSign: exit ? signOf(exit.dir) : 0,
    entryR: 0,
    arcStart: length - (exit ? exit.radius : 0),
  });

  const segments: Record<SegId, RoadSegment> = {
    seg1: seg('seg1', 'N', 40, { dir: 'right', to: 'seg2', radius: R }),
    seg2: seg('seg2', 'E', 40, { dir: 'left',  to: 'seg3', radius: R }),
    seg3: seg('seg3', 'N', 40, null),
  };
  const order: SegId[] = ['seg1', 'seg2', 'seg3'];
  for (const id of order) {
    const s = segments[id];
    if (s.exit) segments[s.exit.to].entryR = s.exit.radius;
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

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error('invariant violated: ' + msg);
}

// We deliberately ALLOW the car past a segment's end (nosing into the
// intersection while still oriented in that segment) and before its start
// (entering, re-orienting). These asserts pin down "how far is reasonable".
export function assertInvariants(s: CarState, world: World): void {
  const seg = world.segments[s.segment];
  assert(Number.isFinite(s.along) && Number.isFinite(s.across) && Number.isFinite(s.angle),
         `finite (${s.along},${s.across},${s.angle})`);
  assert(Math.abs(s.angle) <= Math.PI / 2 + 1e-6, `|angle| <= 90deg (${s.angle})`);
  assert(s.along >= -seg.entryR - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + seg.exitR + 1e-6, `along not far past end (${s.along})`);
  const lateralRoom = seg.width / 2 + Math.max(seg.entryR, seg.exitR) + 1;
  assert(Math.abs(s.across) <= lateralRoom, `across bounded (${s.across})`);
  if (s.turn === null) {
    assert(Math.abs(s.across) < 1e-6 && Math.abs(s.angle) < 1e-6,
           'cruising => centred and aligned');
  }
}

function cruise(state: CarState, seg: RoadSegment, world: World): CarState {
  const target = seg.exit ? seg.arcStart : seg.length;
  const remaining = target - state.along;
  if (remaining > 1e-6) {
    return { ...state, along: Math.min(state.along + cruiseStep(remaining, seg), target) };
  }
  if (!seg.exit) return state;   // parked at the end of the route
  // reached the turn mouth — begin the exit turn and take its first step
  const turn: Turning = { sgn: seg.exitSign, r: seg.exitR, phase: 'exiting', toSeg: seg.exit.to };
  return turnStep({ segment: seg.id, along: seg.arcStart, across: 0, angle: 0, turn }, seg, world);
}

// forward step shrinks from STEP down to the turn's creep as we near the turn
function cruiseStep(remaining: number, seg: RoadSegment): number {
  const creep = seg.exitR > 0 ? seg.exitR * DPHI : STEP;
  if (remaining >= BRAKE_ZONE) return STEP;
  return creep + (STEP - creep) * (remaining / BRAKE_ZONE);
}

function turnStep(state: CarState, seg: RoadSegment, world: World): CarState {
  const t = state.turn as Turning;
  const dHeading = t.sgn * DPHI;
  const ds = t.r * DPHI;                 // forward IN SYNC with rotation
  const mid = state.angle + dHeading / 2;  // midpoint for a tidy integration
  const along = state.along + ds * Math.cos(mid);
  const across = state.across + ds * Math.sin(mid);
  const angle = state.angle + dHeading;

  if (t.phase === 'exiting') {
    if (angle * t.sgn < HANDOFF) return { segment: seg.id, along, across, angle, turn: t };
    return handoff(along, across, angle, seg, world, t);   // arc midpoint -> advance the segment
  }
  // entering: turn until aligned with the new segment, then resume cruising
  if (angle * t.sgn < 0) return { segment: seg.id, along, across, angle, turn: t };
  return { segment: seg.id, along: seg.entryR, across: 0, angle: 0, turn: null };
}

// Re-express the car in the next segment's frame. A and B meet at the corner
// (A's far end, B's start) and are perpendicular, so this is a coordinate swap.
function handoff(along: number, across: number, angle: number,
                 from: RoadSegment, world: World, t: Turning): CarState {
  const L = from.length;
  const nAlong = t.sgn > 0 ? across : -across;   // B's forward = A's right (right turn) / left
  const nAcross = t.sgn > 0 ? L - along : along - L;
  const nAngle = angle - t.sgn * (Math.PI / 2);
  const next = world.segments[t.toSeg];
  return {
    segment: next.id, along: nAlong, across: nAcross, angle: nAngle,
    turn: { sgn: t.sgn, r: next.entryR, phase: 'entering', toSeg: next.id },
  };
}
