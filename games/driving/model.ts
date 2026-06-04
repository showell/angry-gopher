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
//            changes by accel() — a pure function of (along, v, can-the-driver-
//            see-the-intersection-yet). Out of sight: constant acceleration.
//            In sight: the exact constant deceleration that brings the Rider to
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
// by THETA about the shared corner. Continuous; the Rider never jumps.
// =============================================================================

export const DPHI = 0.10;         // heading turned per press in a 90deg turn (rad); sets turn speed AND spin rate
export const V_BASE = 1.2;        // the Rider's speed at the very start of the drive (m/press)
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
export interface TreeLocal { side: 'left' | 'right'; along: number; offset: number; color: string; height: number; pine: boolean }
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
export interface Turning { sgn: number; r: number; angle: number; phase: 'exiting' | 'entering'; toSeg: SegId }
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

export function buildWorld(): World {
  const LANE = 4;   // one lane, ~4m wide
  const R = 2;      // turn radius
  const DEG = Math.PI / 180;

  const seg = (id: SegId, length: number, scheme: Scheme,
               exit: RoadSegment['exit']): RoadSegment => {
    const tan = exit ? exit.radius * Math.tan(exit.angle / 2) : 0;
    return {
      id, length, width: LANE, scheme,
      trees: [],   // filled below, once entry/exit tangents are known
      critters: critterRow(length, LANE / 2),
      exitCritters: elephantRow(length, exit, segNumber(id) > 8 ? 3 : 1),   // late-route elephants are giant
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
    const pine = color === GREEN;         // green trees are conifers; accent trees are round
    const height = pine ? TREE_H / 2 : TREE_H;
    trees.push({ side: 'left', along, offset: 1.5, color, height, pine });
    trees.push({ side: 'right', along, offset: 1.5, color, height, pine });
  }
  return trees;
}
function treeColor(scheme: Scheme, k: number): string {
  if (scheme === 'ALL_GREEN') return GREEN;
  const accent = scheme === 'YELLOW_GREEN' ? YELLOW : RED;
  return k % 2 === 0 ? GREEN : accent;
}

// A cow herd EARLY in the segment (left) and pigs near the END (right), set
// further back than the trees — spread apart so you actually pass them on the
// long, fast roads instead of blowing by a mid-road cluster.
const BULL_ALONG = 24;   // by the 4th tree (trees at entryTan+6, every 6m) — the first cow you meet
const PIG_BACK = 60;     // pigs ~10 trees before the next intersection

function critterRow(length: number, hw: number): CritterLocal[] {
  return [...cowHerd(hw), ...pigRow(length, hw + 10)];
}

// 15 cows early in the segment: a BULL at the front (lowest along — seen first
// as you leave the corner), bigger than the rest and facing the opposite way,
// then 10 full-size cows + 4 half-size calves just behind it in a loose cluster
// (a staggered grid with deterministic jitter — no randomness).
function cowHerd(hw: number): CritterLocal[] {
  const out: CritterLocal[] = [];
  const edge = hw + 10;       // the cows graze well off the road
  const treeX = hw + 1.5;     // the roadside tree line (left side = -treeX)
  const bullH = 1.4 * 1.15;   // just 15% bigger than an adult cow
  // The bull waits by the 4th tree, facing away from the road, its rear (its
  // road-side edge, since it faces left) set back a bit from the tree line.
  out.push({ along: BULL_ALONG, across: -(treeX + bullH / 2 + 0.5), emoji: '🐂', height: bullH, faceRight: false });
  for (let i = 0; i < 14; i++) {
    const col = Math.floor(i / 3), row = i % 3;
    const along = BULL_ALONG + 6 + col * 6 + (row - 1) * 2 + 1.5 * Math.sin(i * 2.7);
    const across = -(edge + row * 5 + 1.2 * Math.cos(i * 1.9));
    const calf = i % 4 === 1;   // i = 1,5,9,13 -> 4 calves at half size
    out.push({ along, across, emoji: '🐄', height: calf ? 0.7 : 1.4, faceRight: true });
  }
  return out;
}

// Four pigs near the end of the segment, on the right.
function pigRow(length: number, edge: number): CritterLocal[] {
  const out: CritterLocal[] = [];
  for (const d of [-6, -2, 2, 6]) {
    out.push({ along: length - PIG_BACK + d, across: edge, emoji: '🐖', height: 1.1, faceRight: false });
  }
  return out;
}

// Beyond the upcoming intersection: an adult elephant and its BABY (cow-sized),
// both to the side OPPOSITE the upcoming turn. The adult faces "left" (rear on
// its right), so we put its REAR — not its middle — on the centreline by
// shifting it half its width; otherwise the wide late-route (3x) body straddles
// the road and overlaps the roadside trees.
function elephantRow(length: number, exit: RoadSegment['exit'], scale: number): CritterLocal[] {
  if (!exit) return [];
  const corner = length + ELEPHANT_AHEAD;
  const adultH = 2.8 * scale, babyH = 1.4 * scale, sign = signOf(exit.dir);
  return [
    { along: corner,     across: -sign * adultH / 2,  emoji: '🐘', height: adultH, faceRight: false },
    { along: corner + 6, across: -sign * 14,          emoji: '🐘', height: babyH, faceRight: false },
  ];
}

// ----------------------------------------------------------------------------
// getNextRiderState — advance the Rider one frame. Pure: (RiderState, World) ->
// the next RiderState. Called explicitly before each draw; the returned state is
// what the renderer is handed.
// ----------------------------------------------------------------------------
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];
  const next = state.turn === null ? cruise(state, seg, world) : turnStep(state, seg, world);
  assertInvariants(next, world);
  return next;
}

// Can the driver see the upcoming intersection yet? Yes once the adult elephant
// beyond it is within SIGHT. (Only meaningful for a segment that HAS a turn; the
// final segment never brakes and is handled directly in accel/cruise.)
function sees(state: RiderState, seg: RoadSegment): boolean {
  if (!seg.exit) return true;
  return seg.length + ELEPHANT_AHEAD - state.along <= SIGHT;
}

// the speed at which a turn is taken (its fixed per-press creep) — the speed the
// approach must decelerate to so motion is continuous into the turn.
const turnSpeed = (seg: RoadSegment): number => seg.exitR * omegaFor(seg.exitAngle);

// Acceleration (m/press^2) PURELY from position, velocity, and visibility:
//   intersection out of sight -> keep accelerating at a constant rate.
//   intersection in view       -> the EXACT constant deceleration that lands the
//     Rider at turn speed (0 at the route end) right at the turn point, from
//     v^2 = vEnd^2 + 2*a*d. Recomputed every press: constant-decel kinematics are
//     self-consistent, so this reproduces the same a each press while correcting
//     integration drift.
function accel(state: RiderState, seg: RoadSegment): number {
  // The final segment (no turn) accelerates the whole way; so does any segment
  // whose turn is still out of sight. Otherwise brake to turn speed.
  if (!seg.exit || !sees(state, seg)) return A_ACCEL;
  const d = seg.arcStart - state.along;
  if (d <= 1e-6) return 0;
  const vEnd = turnSpeed(seg);
  return (vEnd * vEnd - state.v * state.v) / (2 * d);
}

function cruise(state: RiderState, seg: RoadSegment, world: World): RiderState {
  let v = Math.max(0, state.v + accel(state, seg));

  if (!seg.exit) {   // the final segment: accelerate to the end, then the game is over
    const along = state.along + v;
    if (along >= seg.length) return { ...state, along: seg.length, v: 0 };   // reached the end -> stop
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
