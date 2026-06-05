// =============================================================================
// view — pure RIDER-RELATIVE geometry. Given the Rider's state, produce the visible
// scene as primitives measured FROM THE RIDER (forward distance + sideways
// offset). No canvas, no global coordinates: the Rider is the origin.
//
// We render what's around the Rider: each visible segment (its road strip + trees),
// the circular-sector pavement filling each turn's outer corner, and the segments seen
// through the intersections ahead — plus the intersection just behind us.
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

// A point in a segment's BL-ORIGIN frame (x = across from the LEFT edge, 0..W;
// a = along, 0..L) expressed FROM THE RIDER. The Rider's own pose is still centre-
// relative (across = 0 is the centre), so we shift it to from-the-left once, here.
function toRider(a: number, x: number, c: Pose, hw: number): RiderPt {
  const dA = a - c.along, dX = x - (c.across + hw);
  const cos = Math.cos(c.angle), sin = Math.sin(c.angle);
  return { forward: dA * cos + dX * sin, right: -dA * sin + dX * cos };
}

// Map a point from the NEXT segment's BL-origin frame into the CURRENT segment's.
// The segments fuse along the INNER edge of the turn, and LEFT/RIGHT are NOT mirror
// images (random455): a LEFT turn is free — the fused left edges contain the origin,
// so just rotate (CCW) and add the length; a RIGHT turn fuses at the right edge, so
// it pays a road-width shift on x (reference the right edge, rotate CW, shift back).
function nextToCur(aB: number, xB: number, L: number, theta: number, dir: 'left' | 'right', W: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  if (dir === 'left') {
    return { a: aB * cos + xB * sin + L, x: xB * cos - aB * sin };
  }
  return { a: aB * cos - xB * sin + W * sin + L, x: xB * cos + aB * sin + W * (1 - cos) };
}

// the inverse (CURRENT segment's frame -> NEXT segment's frame), same fusion.
function curToNext(a: number, x: number, L: number, theta: number, dir: 'left' | 'right', W: number): { a: number; x: number } {
  const cos = Math.cos(theta), sin = Math.sin(theta);
  if (dir === 'left') {
    const a0 = a - L;
    return { a: a0 * cos - x * sin, x: a0 * sin + x * cos };
  }
  const a0 = a - L - W * sin, x0 = x - W * (1 - cos);
  return { a: a0 * cos + x0 * sin, x: -a0 * sin + x0 * cos };
}

// A wedge of road pavement filling a turn's OUTER corner: a circular sector centred at
// the inner corner P (where the two inner edges fuse), with straight legs P->e1 and
// P->e2 along the two segments' end/start edges out to their outer corners, and an arc
// of radius |P->e1| between them. (P, e1, e2 are already in the Rider's frame; the
// transforms are rigid, so the arc is a true arc here too.)
function sectorQuad(P: RiderPt, e1: RiderPt, e2: RiderPt): Quad {
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
  return { pts, color: ROAD };
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

  const riderHw = chain[0].width / 2;   // the Rider's-frame half-width (its pose is centre-relative)

  // map a point in chain[d]'s BL frame to the Rider's frame, composing the inner-edge
  // join of every segment between it and the Rider. For d = 0 this is just toRider.
  const at = (d: number, a: number, x: number): RiderPt => {
    let pa = a, px = x;
    for (let k = d - 1; k >= 0; k--) {
      const prev = chain[k];   // prev -> chain[k+1] is prev's exit turn
      const dir = prev.exitSign > 0 ? 'right' : 'left';
      const p = nextToCur(pa, px, prev.length, prev.exitAngle, dir, prev.width);
      pa = p.a; px = p.x;
    }
    return toRider(pa, px, c, riderHw);
  };

  for (let d = 0; d < chain.length; d++) {
    const seg = chain[d];
    const hw = seg.width / 2, W = seg.width;

    // road strip in BL coords: x runs 0 (left edge) .. W (right edge)
    quads.push({ pts: [at(d, 0, 0), at(d, 0, W), at(d, seg.length, W), at(d, seg.length, 0)], color: ROAD });

    // pavement for this exit's intersection, whenever the next segment is in view: a
    // sector filling the turn's OUTER corner. innerX is the fused (inner) edge, outerX
    // the far edge — picked by turn direction (right: inner = right edge = W).
    const next = chain[d + 1];
    if (seg.exit && next) {
      const innerX = seg.exitSign > 0 ? W : 0, outerX = W - innerX;
      const outerX2 = seg.exitSign > 0 ? 0 : next.width;
      quads.push(sectorQuad(at(d, seg.length, innerX), at(d, seg.length, outerX), at(d + 1, 0, outerX2)));
    }

    // scenery is still authored centre-relative; +hw shifts it to from-the-left.
    for (const t of seg.trees) {
      trees.push({ at: at(d, t.along, t.across + hw), color: t.color, height: t.height });
    }
    for (const cr of seg.critters) {
      critters.push({ at: at(d, cr.along, cr.across + hw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
    for (const cr of seg.exitCritters) {   // exit decorations, approaching side
      critters.push({ at: at(d, cr.along, cr.across + hw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
  }

  // The intersection just BEHIND us: draw its pavement (defensively, so the corner we
  // just crossed never flashes a gap) plus the previous segment's exit props, both
  // mapped through the join into the current frame.
  const idx = world.order.indexOf(state.segment);
  if (idx > 0) {
    const prev = world.segments[world.order[idx - 1]];
    const dir = prev.exitSign > 0 ? 'right' : 'left';
    const cur = chain[0];
    const innerX = prev.exitSign > 0 ? cur.width : 0, outerX = cur.width - innerX;
    const outerXp = prev.exitSign > 0 ? 0 : prev.width;
    const e1 = curToNext(prev.length, outerXp, prev.length, prev.exitAngle, dir, prev.width);   // prev's outer end corner
    quads.push(sectorQuad(at(0, 0, innerX), toRider(e1.a, e1.x, c, riderHw), at(0, 0, outerX)));
    for (const cr of prev.exitCritters) {
      const p = curToNext(cr.along, cr.across + prev.width / 2, prev.length, prev.exitAngle, dir, prev.width);
      critters.push({ at: toRider(p.a, p.x, c, riderHw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight });
    }
  }

  return { quads, trees, critters };
}
