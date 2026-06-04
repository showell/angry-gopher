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

// a square intersection quad, drawn with a per-segment local->car mapper
function squareAt(at: (a: number, x: number) => CarPt, center: number, hw: number): Quad {
  return {
    pts: [at(center - hw, -hw), at(center + hw, -hw), at(center + hw, hw), at(center - hw, hw)],
    color: ROAD,
  };
}
function treeAcross(side: 'left' | 'right', hw: number, offset: number): number {
  return (side === 'right' ? 1 : -1) * (hw + offset);
}

// how many segments to look ahead (current + this many beyond the next corner)
const LOOK_AHEAD = 3;

export function buildScene(state: CarState, world: World): Scene {
  const c: Pose = { along: state.along, across: state.across, angle: state.angle };
  const quads: Quad[] = [];
  const trees: TreeView[] = [];

  // the car's current segment and up to (LOOK_AHEAD-1) segments beyond it
  const chain: RoadSegment[] = [];
  for (let s: RoadSegment | undefined = world.segments[state.segment];
       s && chain.length < LOOK_AHEAD;
       s = s.exit ? world.segments[s.exit.to] : undefined) {
    chain.push(s);
  }

  for (let d = 0; d < chain.length; d++) {
    const seg = chain[d];
    const hw = seg.width / 2;
    // map a point in seg's frame to the car's frame, composing the exit turns
    // of every segment between it and the car (innermost first). For d = 0 this
    // is just toCar; for each step deeper it adds one more nextToCur.
    const at = (a: number, x: number): CarPt => {
      let pa = a, px = x;
      for (let k = d - 1; k >= 0; k--) {
        const prev = chain[k];   // prev -> chain[k+1] is prev's exit turn
        const p = nextToCur(pa, px, prev.length, prev.exitSign, prev.exitAngle);
        pa = p.a; px = p.x;
      }
      return toCar(pa, px, c);
    };

    quads.push({ pts: [at(0, -hw), at(0, hw), at(seg.length, hw), at(seg.length, -hw)], color: ROAD });
    if (d === 0 && seg.entryR > 0) quads.push(squareAt(at, 0, hw));        // the corner we came through
    if (seg.exit) quads.push(squareAt(at, seg.length, hw));                // each corner ahead
    for (const t of seg.trees) {
      trees.push({ at: at(t.along, treeAcross(t.side, hw, t.offset)), color: t.color });
    }
  }

  return { quads, trees };
}
