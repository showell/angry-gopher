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
import type { CritterView } from './critter.ts';
import type { TreeView } from './tree.ts';

const ROAD = '#34353c';

export interface RiderPt { right: number; forward: number }   // Rider frame, ground plane
export interface Quad { pts: RiderPt[]; color: string }
export interface Scene { quads: Quad[]; trees: TreeView[]; critters: CritterView[] }

// the Rider's pose in its own segment's frame
interface Pose { along: number; across: number; angle: number }

// a segment-local point (along a, across x) expressed FROM THE RIDER
function toRider(a: number, x: number, c: Pose): RiderPt {
  const dA = a - c.along, dX = x - c.across;
  const cos = Math.cos(c.angle), sin = Math.sin(c.angle);
  return { forward: dA * cos + dX * sin, right: -dA * sin + dX * cos };
}

// Map a point in the NEXT segment's frame into the CURRENT segment's frame.
// The segments share an INNER-edge corner: B's begin-inner-corner (BR for a right
// turn, BL for a left) coincides with A's end-inner-corner (ER/EL), at
// (along=L, across=sgn*hw). The transform rotates by sgn*THETA about THAT shared
// corner (not the centre-line point), so the road has width — see random453/454.
function nextToCur(aB: number, xB: number, L: number, sgn: number, theta: number, hw: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  return {
    a: L + hw * sin + aB * cos - xB * sgn * sin,
    x: sgn * hw * (1 - cos) + aB * sgn * sin + xB * cos,
  };
}

// the inverse: a point in the CURRENT segment's frame -> the NEXT segment's frame
// (same shared inner corner). Used to render an intersection's decorations from
// the downstream side.
function curToNext(a: number, x: number, L: number, sgn: number, theta: number, hw: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  const dA = a - L - hw * sin, dX = x - sgn * hw * (1 - cos);
  return { a: dA * cos + dX * sgn * sin, x: -dA * sgn * sin + dX * cos };
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
        const p = nextToCur(pa, px, prev.length, prev.exitSign, prev.exitAngle, prev.width / 2);
        pa = p.a; px = p.x;
      }
      return toRider(pa, px, c);
    };

    quads.push({ pts: [at(0, -hw), at(0, hw), at(seg.length, hw), at(seg.length, -hw)], color: ROAD });
    // (intersection pavement — the fan-shaped overlap region — is drawn separately; TODO thing a.
    //  The old centre-line corner squares are gone: they paved over the inner-edge join.)
    for (const t of seg.trees) {
      trees.push({ at: at(t.along, t.across), color: t.color, height: t.height, pine: t.pine });
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
      const p = curToNext(cr.along, cr.across, prev.length, prev.exitSign, prev.exitAngle, prev.width / 2);
      critters.push({ at: toRider(p.a, p.x, c), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
  }

  return { quads, trees, critters };
}
