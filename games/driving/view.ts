// =============================================================================
// view — pure RIDER-RELATIVE geometry. Given the Rider's state, produce the visible
// scene as primitives measured FROM THE RIDER (forward distance + sideways
// offset). No canvas, no global coordinates: the Rider is the origin.
//
// We render what's around the Rider: each visible segment (its road strip + trees),
// the circular-sector pavement filling each turn's outer corner, and the segments seen
// through the intersections ahead — plus the intersection just behind us.
// =============================================================================
import type { RiderState, DangerSide } from './rider.ts';
import { leanCandidates } from './rider.ts';
import { gazeAngle } from './rider_gaze.ts';
import type { World } from './world.ts';
import type { RoadSegment } from './road_segment.ts';
import { critterScenery } from './critter.ts';
import { catScenery } from './cat_anatomy.ts';
import { catPose } from './cat_motion.ts';
import { treeScenery } from './tree.ts';
import { ROAD } from './scenery.ts';
import type { Scenery, RiderPt, Quad, Poly3 } from './scenery.ts';
import { nextToCur, curToNext, intersectionScene, intersectionTower } from './intersection.ts';
import { towerScenery } from './tower.ts';
import { truckScenery } from './truck.ts';
import type { TruckState } from './truck.ts';

// Road quads are the ground plane (drawn first, no LOD); polys are raised road structures
// (guard rails) drawn over them; scenery is the depth-sorted, near/far-aware drawables (trees
// + critters, merged so they occlude each other right).
export interface Scene { quads: Quad[]; polys: Poly3[]; scenery: Scenery[]; leanPaths: { dots: RiderPt[]; side: DangerSide; chosen: boolean }[] }

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

// How many segments to look ahead. Towers are tall landmarks visible from far off, so they reach
// much further than the road/trees/critters and the corner details (which are short and only read
// up close). Rendering cost is tolerable, so both are generous.
const SCENERY_LOOK_AHEAD = 7;   // road strips, trees, critters, corner sector/rail/creatures
const TOWER_LOOK_AHEAD = 10;    // just the towers

// road strips are sliced into chunks this long (metres) so the ground curvature bends smoothly
const ROAD_CHUNK = 25;

// a segment-owned mid-road tower stands this far to the LEFT of the lane centreline, square-on
const SEG_TOWER_LEFT = 100;

export function buildScene(state: RiderState, world: World, step: number, headYaw: number, truck: TruckState): Scene {
  // the camera looks along the Rider's path PLUS two view-only yaws: his gaze offset (the
  // distracted glance) and a subtle head-turn into the corner (headYaw, from the lean). Both
  // rotate the whole rider-relative scene with where he's looking.
  const c: Pose = { along: state.along, across: state.across, angle: state.yaw + gazeAngle(state) + headYaw };
  const quads: Quad[] = [];
  const polys: Poly3[] = [];
  const scenery: Scenery[] = [];

  // the Rider's current segment and the segments beyond it (out to TOWER_LOOK_AHEAD, the farthest
  // we draw anything), following each segment's exit turn — stopping at the terminus (exit.to ===
  // null), which has no successor.
  const chain: RoadSegment[] = [];
  let s: RoadSegment | undefined = world.segments[state.segment];
  while (s && chain.length < TOWER_LOOK_AHEAD) {
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
    const exitIxn = world.intersections[seg.exitIxn];

    // TOWERS reach the farthest: this segment's exit-intersection tower, plus a mid-road tower if a
    // long segment owns one (halfway down, 100m left of the lane, square-on).
    scenery.push(intersectionTower(exitIxn, seg, (a, x) => at(d, a, x), step));
    if (seg.midTower) {
      scenery.push(towerScenery((a, x) => at(d, a, x), seg.length / 2, hw - SEG_TOWER_LEFT, 0, step, seg.midTower.beaconOffset));
    }

    // everything else (short, only reads up close) stops at the nearer scenery lookahead.
    if (d >= SCENERY_LOOK_AHEAD) continue;

    // road strip in BL coords: x runs 0 (left edge) .. W (right edge). Sliced along its length so
    // the ground curvature (applied per vertex by the renderer) reads as a smooth bend, not a tilt.
    const chunks = Math.max(1, Math.ceil(seg.length / ROAD_CHUNK));
    for (let i = 0; i < chunks; i++) {
      const a0 = (seg.length * i) / chunks, a1 = (seg.length * (i + 1)) / chunks;
      quads.push({ pts: [at(d, a0, 0), at(d, a0, W), at(d, a1, W), at(d, a1, 0)], color: ROAD });
    }

    // scenery is still authored centre-relative; +hw shifts it to from-the-left.
    for (const t of seg.trees) {
      scenery.push(treeScenery({ at: at(d, t.along, t.across + hw), color: t.color, height: t.height }));
    }
    for (const cr of seg.critters) {
      scenery.push(critterScenery({ at: at(d, cr.along, cr.across + hw), emoji: cr.emoji, height: cr.height, faceRight: cr.faceRight }));
    }
    for (const cat of seg.cats) {
      // The cat crosses the road as the rider nears it — but "nears" is measured in the rider's own
      // along-coordinate, which we only have for his current segment (d === 0). Cats further ahead
      // sit at their waiting spot until the rider enters their segment.
      const pose = d === 0 ? catPose(cat, state.along, state.v)
                           : { across: cat.startAcross, walk: 0, headFront: false };
      scenery.push(catScenery({ at: at(d, cat.along, pose.across + hw), height: cat.height, faceRight: cat.faceRight, form: cat.form, walk: pose.walk, headFront: pose.headFront }));
    }

    // this segment's exit JOINT draws its corner details (approach road + sector + rail + creatures).
    // The sector needs the next segment too, so toMap is supplied only when it's in view.
    const next = chain[d + 1];
    const js = intersectionScene(exitIxn, seg, next ?? null,
                                 (a, x) => at(d, a, x), next ? (a, x) => at(d + 1, a, x) : null);
    for (const q of js.quads) quads.push(q);
    for (const p of js.polys) polys.push(p);
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
    scenery.push(intersectionTower(pIxn, prev, fromPrev, step));   // the tower we just passed
    const js = intersectionScene(pIxn, prev, chain[0], fromPrev, (a, x) => at(0, a, x));
    for (const q of js.quads) quads.push(q);
    for (const p of js.polys) polys.push(p);
    for (const sc of js.scenery) scenery.push(sc);
  }

  // the truck we're chasing: somewhere on the road ahead (or null once caught / still too far),
  // mapped through the same chain frames as everything else.
  const truckSc = truckScenery(truck, state, world, chain, at);
  if (truckSc) scenery.push(truckSc);

  // the rider's PROJECTED PATHS — the actual arcs his binary search probed (debug overlay), narrowing in, plus
  // the arc it settled on. Centre-relative points in his current segment's frame; +riderHw shifts to from-the-left, then
  // through the same camera pose as the road.
  const lc = leanCandidates(state, chain[0]);
  const leanPaths = lc.candidates.map((c, idx) => ({
    dots: c.path.map((p) => at(0, p.along, p.across + riderHw)),
    side: c.side,
    chosen: idx === lc.chosen,
  }));

  return { quads, polys, scenery, leanPaths };
}
