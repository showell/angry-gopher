// =============================================================================
// view — pure RIDER-RELATIVE geometry. Given the Rider's state, produce the visible
// scene as primitives measured FROM THE RIDER (forward distance + sideways
// offset). No canvas, no global coordinates: the Rider is the origin.
//
// We render what's around the Rider: each visible segment (its road strip + trees),
// the circular-sector pavement filling each turn's outer corner, and the segments seen
// through the intersections ahead — plus the intersection just behind us.
// =============================================================================
import type { RiderState } from './model.ts';
import type { World, RoadSegment } from './road_segment.ts';
import { critterScenery } from './critter.ts';
import { treeScenery } from './tree.ts';
import { ROAD } from './scenery.ts';
import type { Scenery, RiderPt, Quad } from './scenery.ts';
import { nextToCur, curToNext, intersectionScene } from './intersection.ts';

// Road quads are the ground plane (drawn first, no LOD); scenery is the depth-sorted,
// near/far-aware drawables (trees + critters, merged so they occlude each other right).
export interface Scene { quads: Quad[]; scenery: Scenery[] }

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

// how many segments to look ahead (current + this many beyond the next corner)
const LOOK_AHEAD = 6;

export function buildScene(state: RiderState, world: World): Scene {
  const c: Pose = { along: state.along, across: state.across, angle: state.angle };
  const quads: Quad[] = [];
  const scenery: Scenery[] = [];

  // the Rider's current segment and up to (LOOK_AHEAD-1) segments beyond it, following each
  // segment's exit turn — stopping at the terminus (exit.to === null), which has no successor.
  const chain: RoadSegment[] = [];
  let s: RoadSegment | undefined = world.segments[state.segment];
  while (s && chain.length < LOOK_AHEAD) {
    chain.push(s);
    const to: string | null = world.intersections[s.exitIxn].to;
    s = to ? world.segments[to] : undefined;
  }

  const riderHw = chain[0].width / 2;   // the Rider's-frame half-width (its pose is centre-relative)

  // map a point in chain[d]'s BL frame to the Rider's frame, composing the inner-edge
  // join of every segment between it and the Rider. For d = 0 this is just toRider.
  const at = (d: number, a: number, x: number): RiderPt => {
    let pa = a, px = x;
    for (let k = d - 1; k >= 0; k--) {
      const prev = chain[k];   // prev -> chain[k+1] is prev's exit turn
      const ixn = world.intersections[prev.exitIxn];
      const dir = ixn.sign > 0 ? 'right' : 'left';
      const p = nextToCur(pa, px, prev.length, ixn.angle, dir, prev.width);
      pa = p.a; px = p.x;
    }
    return toRider(pa, px, c, riderHw);
  };

  for (let d = 0; d < chain.length; d++) {
    const seg = chain[d];
    const hw = seg.width / 2, W = seg.width;

    // road strip in BL coords: x runs 0 (left edge) .. W (right edge)
    quads.push({ pts: [at(d, 0, 0), at(d, 0, W), at(d, seg.length, W), at(d, seg.length, 0)], color: ROAD });

    // scenery is still authored centre-relative; +hw shifts it to from-the-left.
    for (const t of seg.trees) {
      scenery.push(treeScenery({ at: at(d, t.along, t.across + hw), color: t.color, height: t.height }));
    }
    for (const cr of seg.critters) {
      scenery.push(critterScenery({ at: at(d, cr.along, cr.across + hw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight }));
    }

    // this segment's exit JOINT draws itself: approach road + corner sector + elephants.
    // The sector needs the next segment too, so toMap is supplied only when it's in view.
    const exitIxn = world.intersections[seg.exitIxn];
    const next = chain[d + 1];
    const js = intersectionScene(exitIxn, seg, next ?? null,
                                 (a, x) => at(d, a, x), next ? (a, x) => at(d + 1, a, x) : null);
    for (const q of js.quads) quads.push(q);
    for (const sc of js.scenery) scenery.push(sc);
  }

  // The joint just BEHIND us draws itself too — its approach road keeps the segment we just
  // left from vanishing mid-crossing, plus its corner sector and elephants — all mapped
  // through the join into the current frame.
  const idx = world.order.indexOf(state.segment);
  if (idx > 0) {
    const prev = world.segments[world.order[idx - 1]];
    const pIxn = world.intersections[prev.exitIxn];   // the joint we just crossed
    const dir = pIxn.sign > 0 ? 'right' : 'left';
    const Wp = prev.width;
    // a point in PREV's BL frame, mapped into the Rider's frame through the join.
    const fromPrev = (a: number, x: number): RiderPt => {
      const p = curToNext(a, x, prev.length, pIxn.angle, dir, Wp);
      return toRider(p.a, p.x, c, riderHw);
    };
    const js = intersectionScene(pIxn, prev, chain[0], fromPrev, (a, x) => at(0, a, x));
    for (const q of js.quads) quads.push(q);
    for (const sc of js.scenery) scenery.push(sc);
  }

  return { quads, scenery };
}
