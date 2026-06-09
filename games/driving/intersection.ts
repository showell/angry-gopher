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
import { buildGuardRail, RAIL_RUNOUT, RAIL_POST_SPACING_DEG } from './guard_rail.ts';

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
// sector, and the elephants. The caller hands us a mapper for the INCOMING segment `from`
// (fromMap) and, when the outgoing segment is in view, one for `to` (toMap) — the sector
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

  // the corner pavement sector — a wedge from the inner fuse-corner out to the two outer
  // corners (one on each segment). Inner/outer flip with turn direction; pavementSector
  // sweeps the short way either way, so it's the shared piece. The guard rail rides the same
  // outer arc.
  if (toMap && to) {
    let inner: RiderPt, outerFrom: RiderPt, outerTo: RiderPt;
    if (ixn.sign > 0) {                 // RIGHT turn: the segments fuse on `from`'s end-RIGHT edge
      inner     = corner(W, 0);         //   inner corner = end-right (the far one)
      outerFrom = corner(0, 0);         //   outer corner on `from` = end-left (the origin)
      outerTo   = toMap(0, 0);          //   outer corner on `to`   = its start-left edge
    } else {                            // LEFT turn: the segments fuse on `from`'s end-LEFT edge
      inner     = corner(0, 0);         //   inner corner = end-left (the origin)
      outerFrom = corner(W, 0);         //   outer corner on `from` = end-right
      outerTo   = toMap(0, to.width);   //   outer corner on `to`   = its start-right edge
    }
    quads.push({ pts: pavementSector(inner, outerFrom, outerTo), color: ROAD });

    // the guard rail's ground path: a run-up along `from`'s outer edge, around the corner arc,
    // and a run-out along `to`'s outer edge. The outer edge is the LEFT (x=0) of each on a right
    // turn, the RIGHT on a left turn — the same sides the sector's outer corners sit on.
    const fromOuterCu = ixn.sign > 0 ? 0 : W;          // `from`'s outer edge (corner-frame across)
    const toOuterX = ixn.sign > 0 ? 0 : to.width;      // `to`'s outer edge (its BL across)
    const arc = cornerArc(inner, outerFrom, outerTo);
    const arcPosts = Math.max(1, Math.round(Math.abs(arc.delta) / (RAIL_POST_SPACING_DEG * Math.PI / 180)));
    const railPath: RiderPt[] = [];
    for (let m = RAIL_RUNOUT; m >= 1; m--) railPath.push(corner(fromOuterCu, -m));         // run-up into the arc
    for (let i = 0; i <= arcPosts; i++) railPath.push(onArc(arc, arc.a1 + arc.delta * (i / arcPosts)));
    for (let m = 1; m <= RAIL_RUNOUT; m++) railPath.push(toMap(m, toOuterX));              // run-out past the arc
    for (const p of buildGuardRail(railPath)) polys.push(p);
  }

  // the emoji creatures parked at the corner (authored centre-relative; +hw shifts to from-the-left).
  for (const cr of ixn.creatures) {
    scenery.push(critterScenery({ at: fromMap(cr.along, cr.across + hw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight }));
  }

  // the corner's hand-drawn extras (the crocodile lagoon) — safari_critter hands off to the right
  // module, placed along the OUTGOING road (toMap) so the lagoon stretches past the turn, not sideways.
  const extras = cornerCreatureExtras(ixn.creature, Number(from.id.slice(3)), toMap);
  for (const q of extras.quads) quads.push(q);
  for (const s of extras.scenery) scenery.push(s);

  return { quads, polys, scenery };
}

// The max speed (m/press) at which each turn angle is taken: the Rider holds this through
// the angle-kill, drifting to the far edge and recentring without leaving the road. These
// are NOT a closed form — they were found by offline simulation of THIS straighten-out
// (jerk-limited rotation up to TURN_OMEGA, braking-profile recentre), binary-searching the
// fastest entry whose far-edge drift stays STRAIGHTEN_MARGIN inside the edge. "An expert
// Rider knows safe turn speeds." Only the route's six angles are tabulated; an unlisted
// angle is a config error — re-run the sim and add it (linear interp OVER-estimates, unsafe).
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

// ---- the corner arc, shared by the pavement and the guard rail ----
// The arc centred at the inner corner P (where the two inner edges fuse), radius |P->e1|,
// swept the SHORT way from e1's bearing to e2's (= the turn angle). P, e1, e2 are already
// in the Rider's frame; the transforms are rigid, so the arc is a true arc here too.
interface CornerArc { P: RiderPt; R: number; a1: number; delta: number }
function cornerArc(P: RiderPt, e1: RiderPt, e2: RiderPt): CornerArc {
  const R = Math.hypot(e1.right - P.right, e1.forward - P.forward);
  const a1 = Math.atan2(e1.forward - P.forward, e1.right - P.right);
  let delta = Math.atan2(e2.forward - P.forward, e2.right - P.right) - a1;
  while (delta > Math.PI) delta -= 2 * Math.PI;
  while (delta < -Math.PI) delta += 2 * Math.PI;
  return { P, R, a1, delta };
}
const onArc = (c: CornerArc, ang: number): RiderPt =>
  ({ right: c.P.right + c.R * Math.cos(ang), forward: c.P.forward + c.R * Math.sin(ang) });

// ---- the pavement that fills the turn's outer corner ----
// A circular SECTOR: straight legs P->e1 and P->e2 along the two segments' end/start edges
// out to their outer corners, and the arc between them. Returns the polygon outline; the
// caller paints it road-colour.
export function pavementSector(P: RiderPt, e1: RiderPt, e2: RiderPt): RiderPt[] {
  const c = cornerArc(P, e1, e2);
  const pts: RiderPt[] = [P];
  const N = 8;
  for (let i = 0; i <= N; i++) pts.push(onArc(c, c.a1 + c.delta * (i / N)));
  return pts;
}
