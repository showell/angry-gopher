// =============================================================================
// view — pure RIDER-RELATIVE geometry. Given the Rider's state, produce the visible
// scene as primitives measured FROM THE RIDER (forward distance + sideways
// offset). No canvas, no global coordinates: the Rider is the origin.
//
// We render only what's around the Rider: the current segment (its road strip,
// its intersection squares, its trees) and the NEXT segment seen through the
// intersection. Nothing behind us.
// =============================================================================
import type { World, RiderState, RoadSegment } from './model.ts';

const ROAD = '#34353c';

export interface RiderPt { right: number; forward: number }   // Rider frame, ground plane
export interface Quad { pts: RiderPt[]; color: string }
export interface TreeView { at: RiderPt; color: string; height: number; pine: boolean }
export interface CritterView { at: RiderPt; emoji: string; height: number; faceRight: boolean }
export interface Scene { quads: Quad[]; trees: TreeView[]; critters: CritterView[] }

// the Rider's pose in its own segment's frame
interface Pose { along: number; across: number; angle: number }

// a segment-local point (along a, across x) expressed FROM THE RIDER
function toRider(a: number, x: number, c: Pose): RiderPt {
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

// the inverse: a point in the CURRENT segment's frame -> the NEXT segment's
// frame (the A->B handoff). Used to render an intersection's decorations from
// the downstream side.
function curToNext(a: number, x: number, L: number, sgn: number, theta: number): { a: number; x: number } {
  const dA = a - L, cosB = Math.cos(theta), sinB = sgn * Math.sin(theta);
  return { a: dA * cosB + x * sinB, x: -dA * sinB + x * cosB };
}

// a square intersection quad, drawn with a per-segment local->Rider mapper
function squareAt(at: (a: number, x: number) => RiderPt, center: number, hw: number): Quad {
  return {
    pts: [at(center - hw, -hw), at(center + hw, -hw), at(center + hw, hw), at(center - hw, hw)],
    color: ROAD,
  };
}
function treeAcross(side: 'left' | 'right', hw: number, offset: number): number {
  return (side === 'right' ? 1 : -1) * (hw + offset);
}

// how many segments to look ahead (current + this many beyond the next corner)
const LOOK_AHEAD = 4;

export function buildScene(state: RiderState, world: World): Scene {
  const c: Pose = { along: state.along, across: state.across, angle: state.angle };
  const quads: Quad[] = [];
  const trees: TreeView[] = [];
  const critters: CritterView[] = [];

  // the Rider's current segment and up to (LOOK_AHEAD-1) segments beyond it
  const chain: RoadSegment[] = [];
  for (let s: RoadSegment | undefined = world.segments[state.segment];
       s && chain.length < LOOK_AHEAD;
       s = s.exit ? world.segments[s.exit.to] : undefined) {
    chain.push(s);
  }

  for (let d = 0; d < chain.length; d++) {
    const seg = chain[d];
    const hw = seg.width / 2;
    // map a point in seg's frame to the Rider's frame, composing the exit turns
    // of every segment between it and the Rider (innermost first). For d = 0 this
    // is just toRider; for each step deeper it adds one more nextToCur.
    const at = (a: number, x: number): RiderPt => {
      let pa = a, px = x;
      for (let k = d - 1; k >= 0; k--) {
        const prev = chain[k];   // prev -> chain[k+1] is prev's exit turn
        const p = nextToCur(pa, px, prev.length, prev.exitSign, prev.exitAngle);
        pa = p.a; px = p.x;
      }
      return toRider(pa, px, c);
    };

    quads.push({ pts: [at(0, -hw), at(0, hw), at(seg.length, hw), at(seg.length, -hw)], color: ROAD });
    if (d === 0 && seg.entryR > 0) quads.push(squareAt(at, 0, hw));        // the corner we came through
    if (seg.exit) quads.push(squareAt(at, seg.length, hw));                // each corner ahead
    for (const t of seg.trees) {
      trees.push({ at: at(t.along, treeAcross(t.side, hw, t.offset)), color: t.color, height: t.height, pine: t.pine });
    }
    for (const cr of seg.critters) {
      critters.push({ at: at(cr.along, cr.across), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
    // exit intersection decorations, rendered from the APPROACHING side
    for (const cr of seg.exitCritters) {
      critters.push({ at: at(cr.along, cr.across), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
  }

  // The intersection just behind us belongs to BOTH segments. Render the
  // current segment's ENTRY decorations — the previous segment's exit props,
  // mapped through the handoff into the current frame — so a corner prop stays
  // continuous across the A->B handoff instead of popping out of the chain.
  const idx = world.order.indexOf(state.segment);
  if (idx > 0) {
    const prev = world.segments[world.order[idx - 1]];
    for (const cr of prev.exitCritters) {
      const p = curToNext(cr.along, cr.across, prev.length, prev.exitSign, prev.exitAngle);
      critters.push({ at: toRider(p.a, p.x, c), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
  }

  return { quads, trees, critters };
}
