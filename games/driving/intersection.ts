// =============================================================================
// intersection — the JOINT between two road segments, where everything technical
// in the game happens: the rider commits to the turn, the two segments' frames
// fuse, and the corner's pavement is drawn. A segment is just the straight part
// between two of these.
//
// The Intersection is now a first-class NODE: the road is a graph of these joined
// by RoadSegment edges (road_segment.ts). The turn lives ON the intersection
// (dir/angle/radius), not smeared across the two adjoining segments. This module
// owns both the type and its behaviour: the safe turn speed, the frame-fusion
// transforms, and the pavement wedge.
// =============================================================================

import { critterScenery } from './critter.ts';
import type { Critter } from './critter.ts';
import { cornerCritters, cornerCreatureExtras } from './safari_critter.ts';
import type { CornerCreature } from './safari_critter.ts';
import { towerScenery, beaconOffsetFor } from './tower.ts';
import { ROAD } from './scenery.ts';
import type { RiderPt, Quad, Poly3, Scenery } from './scenery.ts';
import type { SegId, TurnDir, RoadSegment } from './road_segment.ts';
import { buildGuardRail, RAIL_RUNOUT } from './guard_rail.ts';

export type IxnId = string;

// where this intersection stands its tower: out past the corner, off to the right, yawed off
// head-on (so two faces show). The intersection OWNS this placement; tower.ts only renders.
const TOWER_BEYOND = 160;             // metres past the corner, along the approach direction
const TOWER_RIGHT = 20;               // metres right of the lane centreline
const TOWER_YAW = 30 * Math.PI / 180; // turned off head-on

const TURN_RADIUS = 2;        // corner radius; sets the pavement wedge and the `tan` clear-zone half.
const ENTRY_ROAD_DIST = 40;   // metres of approach road the joint paints behind its edge (the rest of
                              // the segment draws its own strip; this only needs to cover the joint when
                              // it's the one BEHIND the Rider). Safe to fix — segments are always long enough.
const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);

// An intersection: the turn that joins one segment to the next. For now it carries the
// turn DIRECTLY (angle/radius/sign) rather than wrapping a separate Turn object — fine
// while there's exactly one outgoing edge. `to` is that single outgoing segment; it
// becomes the CHOSEN fork once the rider gets to pick. (`from`/`to` make this a real
// graph edge; segments carry the reverse refs.)
//
// A TERMINUS — where the route opens or closes — is a degenerate intersection with
// `to: null` (no outgoing fork), angle 0 and sign 0. The Rider arrives and stops; there
// is no turn. (Only the END terminus is modelled as a node: every segment exits through
// an intersection. The START isn't — the Rider just spawns on seg1 — so it earns no node.)
export interface Intersection {
  id: IxnId;
  from: SegId;        // the segment arriving at this intersection
  to: SegId | null;   // the segment leaving it (chosen fork; singular for now). null = TERMINUS.
  angle: number;      // turn angle THETA (rad); 0 at a terminus
  radius: number;     // corner radius
  sign: number;       // +1 right, -1 left; 0 = no turn (terminus)
  tan: number;        // radius * tan(THETA/2): the corner's half-tangent (how far the turn intrudes into a straight); 0 at a terminus
  creature: CornerCreature | null;   // the authored species at this corner (null at a terminus) — drives the emoji pair AND the crocodile lagoon
  creatures: Critter[];   // the emoji creatures parked here (elephants/giraffes/zebras; empty for a crocodile or terminus); the joint OWNS them
  beaconOffset: number;   // authored blink-phase offset for this tower's apex beacon, so towers don't pulse in unison
}

// Build the turn NODE joining `from` to `to`. Pure: it reads the two segments' ids and
// returns the Intersection (including the creatures parked at the corner); the caller wires
// the reverse graph refs onto the segments.
export function buildIntersection(from: RoadSegment, to: RoadSegment, dir: TurnDir, angle: number, creature: CornerCreature): Intersection {
  const sign = signOf(dir);
  const segNum = Number(from.id.slice(3));   // "seg12" -> 12; late-route corners get giant creatures
  return {
    id: `${from.id}_${to.id}`,
    from: from.id, to: to.id, angle,
    radius: TURN_RADIUS, sign, tan: TURN_RADIUS * Math.tan(angle / 2),
    creature,
    creatures: cornerCritters(creature, from.length, sign, segNum, from.width / 2),
    beaconOffset: beaconOffsetFor(segNum),
  };
}

// Build the TERMINUS node that closes the route off `from`: a degenerate intersection
// with no outgoing fork (the Rider arrives and stops). No turn, so angle/sign/tan are 0
// and there are no creatures.
export function buildTerminus(from: RoadSegment): Intersection {
  return { id: `${from.id}_end`, from: from.id, to: null, angle: 0, radius: 0, sign: 0, tan: 0, creature: null, creatures: [],
           beaconOffset: beaconOffsetFor(Number(from.id.slice(3))) };
}

// ---- the intersection as a SCENE CONTRIBUTOR ----
// A point in a segment's BL frame (a along, x across-from-left) mapped into the Rider's frame.
export type FrameMap = (a: number, x: number) => RiderPt;

// Everything this joint draws, in the Rider's frame: the approach road, the corner pavement
// quad, and the elephants. The caller hands us a mapper for the INCOMING segment `from`
// (fromMap) and, when the outgoing segment is in view, one for `to` (toMap) — the quad
// needs a point from each side, so it's drawn only when toMap is present.
//
// We author everything relative to `from`'s END-LEFT corner: corner(cu, cv) puts the origin
// there, with cu running ACROSS the terminating edge (toward end-right) and cv perpendicular
// (negative = back down the approach road). Left and right exits are coded independently —
// no sign-multiplier symmetry — because the geometry genuinely differs: a LEFT turn fuses on
// the end-LEFT edge (the origin itself is the inner corner), a RIGHT turn fuses on the
// end-RIGHT edge (the inner corner is the far one).
// The radio tower this intersection OWNS: out past the corner, off to the right, yawed off head-on
// (terminus included — a landmark straight ahead as the road ends). Kept SEPARATE from
// intersectionScene so towers, being tall landmarks, can be drawn much farther ahead than the
// corner details (sector / rail / creatures), which only matter up close.
export function intersectionTower(ixn: Intersection, from: RoadSegment, fromMap: FrameMap, step: number): Scenery {
  return towerScenery(fromMap, from.length + TOWER_BEYOND, from.width / 2 + TOWER_RIGHT, TOWER_YAW, step, ixn.beaconOffset);
}

export function intersectionScene(ixn: Intersection, from: RoadSegment, to: RoadSegment | null,
                                  fromMap: FrameMap, toMap: FrameMap | null): { quads: Quad[]; polys: Poly3[]; scenery: Scenery[] } {
  if (ixn.to === null) return { quads: [], polys: [], scenery: [] };   // terminus: no corner geometry (its tower is drawn separately)
  const W = from.width, hw = W / 2;
  const corner = (cu: number, cv: number): RiderPt => fromMap(from.length + cv, cu);

  const quads: Quad[] = [];
  const polys: Poly3[] = [];
  const scenery: Scenery[] = [];

  // the approach road: `from`'s tail leading into the joint (end edge back ENTRY_ROAD_DIST).
  quads.push({ pts: [corner(0, 0), corner(W, 0), corner(W, -ENTRY_ROAD_DIST), corner(0, -ENTRY_ROAD_DIST)], color: ROAD });

  // The corner PAVEMENT is a QUADRILATERAL, not a circular sector. Its two SHORT ends are the segments'
  // end/begin edges; its two LONG sides are the OUTER shoulder lines (the ones OPPOSITE the turn) extended
  // into the joint until they cross at the outer APEX Q. This matches what the braking/turning model assumes —
  // each segment extends straight into the joint, so any point inside is "in the lane" of one segment or the
  // other. The guard rail rides those same outer shoulders, now meeting at the sharp apex Q (no arc).
  if (toMap && to) {
    const fromOuterCu = ixn.sign > 0 ? 0 : W;          // `from`'s OUTER edge (corner-frame across) — opposite the turn
    const toOuterX = ixn.sign > 0 ? 0 : to.width;      // `to`'s OUTER edge (its BL across) — opposite the turn
    const inner     = corner(ixn.sign > 0 ? W : 0, 0); // the inner fuse-corner where the two INNER edges meet
    const outerFrom = corner(fromOuterCu, 0);          // `from`'s outer corner, at its end edge
    const outerTo   = toMap(0, toOuterX);              // `to`'s outer corner, at its begin edge
    // the outer APEX: the two outer-shoulder lines, extended into the joint, cross here.
    const Q = lineMeet(outerFrom, corner(fromOuterCu, 1), outerTo, toMap(1, toOuterX));

    quads.push({ pts: [inner, outerFrom, Q, outerTo], color: ROAD });

    // the guard rail: a run-up along `from`'s outer edge, the two legs INTO and OUT OF the apex Q, then a
    // run-out along `to`'s outer edge — ~1 post per metre throughout (buildGuardRail posts every path point).
    const railPath: RiderPt[] = [];
    for (let m = RAIL_RUNOUT; m >= 0; m--) railPath.push(corner(fromOuterCu, -m));   // run-up to the end edge (m=0 = outerFrom)
    pushLeg(railPath, outerFrom, Q);                                                 // leg into the apex
    pushLeg(railPath, Q, outerTo);                                                   // leg out of the apex
    for (let m = 1; m <= RAIL_RUNOUT; m++) railPath.push(toMap(m, toOuterX));        // run-out from the begin edge
    for (const p of buildGuardRail(railPath)) polys.push(p);
  }

  // the emoji creatures parked at the corner (authored centre-relative; +hw shifts to from-the-left).
  for (const cr of ixn.creatures) {
    scenery.push(critterScenery({ at: fromMap(cr.along, cr.across + hw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight }));
  }

  // the corner's hand-drawn extras (the crocodile lagoon) — safari_critter hands off to the right
  // module, in the same incoming corner frame the pavement sector uses.
  const extras = cornerCreatureExtras(ixn.creature, Number(from.id.slice(3)), corner);
  for (const q of extras.quads) quads.push(q);
  for (const s of extras.scenery) scenery.push(s);

  return { quads, polys, scenery };
}

// The max speed (m/press) at which each turn angle is taken: the Rider brakes to this entry
// speed by the commit point, then leans into the corner without leaving the road. These are
// NOT a closed form — they were found by offline simulation, binary-searching the fastest
// entry whose far-edge drift stays STRAIGHTEN_MARGIN inside the edge. "An expert Rider knows
// safe turn speeds." Only the route's six angles are tabulated; an unlisted angle is a config
// error — re-run the sim and add it (linear interp OVER-estimates, unsafe).
// NOTE: these values predate the tilt-driven turning rework (they were derived under the old
// jerk-limited straighten model); replacing this table with live self-computation is queued.
const SAFE_TURN_SPEED: Record<number, number> = {
  15: 1.297, 20: 0.840, 30: 0.461, 50: 0.222, 70: 0.139, 80: 0.117,
};
export function turnSpeed(ixn: Intersection): number {
  if (ixn.to === null) return 0;   // a terminus: the route ends here, so the approach coasts to a stop
  const deg = Math.round(ixn.angle * 180 / Math.PI);
  const v = SAFE_TURN_SPEED[deg];
  if (v === undefined) throw new Error(`no safe turn speed tabulated for a ${deg}deg turn (${ixn.id})`);
  return v;
}

// ---- frame fusion: how the two segments meet across the joint ----
// The segments fuse along the INNER edge of the turn, and LEFT/RIGHT are NOT mirror
// images (random455): a LEFT turn is free — the fused left edges contain the origin,
// so just rotate (CCW) and add the length; a RIGHT turn fuses at the right edge, so
// it pays a road-width shift on x (reference the right edge, rotate CW, shift back).

// Map a point from the NEXT segment's BL-origin frame into the CURRENT segment's.
export function nextToCur(aB: number, xB: number, L: number, theta: number, dir: 'left' | 'right', W: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  if (dir === 'left') {
    return { a: aB * cos + xB * sin + L, x: xB * cos - aB * sin };
  }
  return { a: aB * cos - xB * sin + W * sin + L, x: xB * cos + aB * sin + W * (1 - cos) };
}

// the inverse (CURRENT segment's frame -> NEXT segment's frame), same fusion.
export function curToNext(a: number, x: number, L: number, theta: number, dir: 'left' | 'right', W: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  if (dir === 'left') {
    const a0 = a - L;
    return { a: a0 * cos - x * sin, x: a0 * sin + x * cos };
  }
  const a0 = a - L - W * sin, x0 = x - W * (1 - cos);
  return { a: a0 * cos + x0 * sin, x: -a0 * sin + x0 * cos };
}

// ---- corner-quad geometry, shared by the pavement and the guard rail ----

// Where two infinite lines cross, in the Rider's (right, forward) frame: line A through a0 toward a1, line B
// through b0 toward b1. Used for the outer APEX where the two segments' outer shoulders, extended into the
// joint, meet. A real intersection has a non-zero turn angle, so the lines are never parallel.
function lineMeet(a0: RiderPt, a1: RiderPt, b0: RiderPt, b1: RiderPt): RiderPt {
  const dax = a1.right - a0.right, daf = a1.forward - a0.forward;
  const dbx = b1.right - b0.right, dbf = b1.forward - b0.forward;
  const t = ((b0.right - a0.right) * dbf - (b0.forward - a0.forward) * dbx) / (dax * dbf - daf * dbx);
  return { right: a0.right + t * dax, forward: a0.forward + t * daf };
}

// Append points stepping from `from` (EXCLUSIVE) to `to` (inclusive) at ~1m spacing — one guard-rail post per
// metre along a straight leg of the corner.
function pushLeg(path: RiderPt[], from: RiderPt, to: RiderPt): void {
  const n = Math.max(1, Math.round(Math.hypot(to.right - from.right, to.forward - from.forward)));
  for (let i = 1; i <= n; i++)
    path.push({ right: from.right + (to.right - from.right) * (i / n), forward: from.forward + (to.forward - from.forward) * (i / n) });
}
