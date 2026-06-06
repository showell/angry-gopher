// =============================================================================
// intersection — the JOINT between two road segments, where everything technical
// in the game happens: the rider commits to the turn, the two segments' frames
// fuse, and the corner's pavement is drawn. A segment is just the straight part
// between two of these.
//
// For now an intersection has no instance of its own — its data still lives as the
// exit/entry fields on the adjoining RoadSegments (road_segment.ts). This module
// owns the BEHAVIOUR keyed off that data: the safe turn speed, the frame-fusion
// transforms, and the pavement wedge. Giving the intersection a real type (and
// moving the turn data onto it) is the next step.
// =============================================================================

import type { RiderPt } from './scenery.ts';
import type { RoadSegment } from './road_segment.ts';

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
export function turnSpeed(seg: RoadSegment): number {
  const deg = Math.round(seg.exitAngle * 180 / Math.PI);
  const v = SAFE_TURN_SPEED[deg];
  if (v === undefined) throw new Error(`no safe turn speed tabulated for a ${deg}deg turn (${seg.id})`);
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

// ---- the pavement that fills the turn's outer corner ----
// A circular SECTOR centred at the inner corner P (where the two inner edges fuse), with
// straight legs P->e1 and P->e2 along the two segments' end/start edges out to their
// outer corners, and an arc of radius |P->e1| between them. (P, e1, e2 are already in the
// Rider's frame; the transforms are rigid, so the arc is a true arc here too.) Returns the
// polygon outline; the caller paints it road-colour.
export function pavementSector(P: RiderPt, e1: RiderPt, e2: RiderPt): RiderPt[] {
  const R = Math.hypot(e1.right - P.right, e1.forward - P.forward);
  const a1 = Math.atan2(e1.forward - P.forward, e1.right - P.right);
  let delta = Math.atan2(e2.forward - P.forward, e2.right - P.right) - a1;
  while (delta > Math.PI) delta -= 2 * Math.PI;
  while (delta < -Math.PI) delta += 2 * Math.PI;   // sweep the SHORT way (= the turn angle)
  const pts: RiderPt[] = [P];
  const N = 8;
  for (let i = 0; i <= N; i++) {
    const ang = a1 + delta * (i / N);
    pts.push({ right: P.right + R * Math.cos(ang), forward: P.forward + R * Math.sin(ang) });
  }
  return pts;
}
