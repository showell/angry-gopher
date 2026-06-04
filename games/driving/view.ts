// =============================================================================
// view — pure CAR-RELATIVE geometry. Given the car's state, produce the visible
// scene as primitives measured FROM THE CAR (forward distance + sideways
// offset). No canvas, no global coordinates: the car is the origin.
//
// We render only what's around the car: the current segment (its road strip,
// its intersection squares, its trees) and the NEXT segment seen through the
// intersection. Nothing behind us.
// =============================================================================
import type { World, CarState, RoadSegment } from './model.ts';

const ROAD = '#34353c';
export const TREE_H = 5;

export interface CarPt { right: number; forward: number }   // car frame, ground plane
export interface Quad { pts: CarPt[]; color: string }
export interface TreeView { at: CarPt; color: string }       // color = the segment's foliage
export interface Scene { quads: Quad[]; trees: TreeView[] }

// the car's pose in its own segment's frame
interface Pose { along: number; across: number; angle: number }

// a segment-local point (along a, across x) expressed FROM THE CAR
function toCar(a: number, x: number, c: Pose): CarPt {
  const dA = a - c.along, dX = x - c.across;
  const cos = Math.cos(c.angle), sin = Math.sin(c.angle);
  return { forward: dA * cos + dX * sin, right: -dA * sin + dX * cos };
}

// map a point in the NEXT segment's frame into the CURRENT segment's frame.
// B starts at A's corner (along = L), rotated by sgn*THETA. Reduces to the
// simple swap at 90deg.
function nextToCur(aB: number, xB: number, L: number, sgn: number, theta: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  return { a: L + aB * cos - xB * sgn * sin, x: aB * sgn * sin + xB * cos };
}

function strip(a0: number, a1: number, hw: number, c: Pose): Quad {
  return { pts: [toCar(a0, -hw, c), toCar(a0, hw, c), toCar(a1, hw, c), toCar(a1, -hw, c)], color: ROAD };
}
function square(aCenter: number, hw: number, c: Pose): Quad {
  return {
    pts: [toCar(aCenter - hw, -hw, c), toCar(aCenter + hw, -hw, c),
          toCar(aCenter + hw, hw, c), toCar(aCenter - hw, hw, c)],
    color: ROAD,
  };
}
function treeAcross(side: 'left' | 'right', hw: number, offset: number): number {
  return (side === 'right' ? 1 : -1) * (hw + offset);
}

export function buildScene(state: CarState, world: World): Scene {
  const cur = world.segments[state.segment];
  const c: Pose = { along: state.along, across: state.across, angle: state.angle };
  const hw = cur.width / 2;
  const quads: Quad[] = [];
  const trees: TreeView[] = [];

  // current segment: road strip + (any) intersection squares
  quads.push(strip(0, cur.length, hw, c));
  if (cur.entryR > 0) quads.push(square(0, hw, c));            // the corner we came through
  if (cur.exit) quads.push(square(cur.length, hw, c));          // the corner ahead

  // next segment through the intersection
  if (cur.exit) {
    const nxt: RoadSegment = world.segments[cur.exit.to];
    const L = cur.length, sgn = cur.exitSign, nhw = nxt.width / 2, theta = cur.exitAngle;
    const m = (aB: number, xB: number): CarPt => {
      const p = nextToCur(aB, xB, L, sgn, theta);
      return toCar(p.a, p.x, c);
    };
    quads.push({ pts: [m(0, -nhw), m(0, nhw), m(nxt.length, nhw), m(nxt.length, -nhw)], color: ROAD });
    for (const t of nxt.trees) {
      trees.push({ at: m(t.along, treeAcross(t.side, nhw, t.offset)), color: t.color });
    }
  }

  // current segment trees
  for (const t of cur.trees) {
    trees.push({ at: toCar(t.along, treeAcross(t.side, hw, t.offset), c), color: t.color });
  }

  return { quads, trees };
}
