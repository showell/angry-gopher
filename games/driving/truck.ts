// truck.ts — the vehicle we chase: a bright red rectangular prism that drives the route ahead of us
// and which we slowly reel in. It rides the CENTRE LINE of whatever segment it's on (no lean, no lane
// drift), so its box is built straight in that segment's frame and inherits the segment/arc heading.
// Its speed is tied to ours — it covers SPEED_FRACTION of the distance we cover — so starting
// START_AHEAD in front, the gap closes steadily until we catch it. v1: once caught it simply stops
// being drawn (what happens on contact is a later problem). It obeys the same ground-curvature +
// near-plane rules as the road it sits on.

import { groundDrop, clipNear } from './scenery.ts';
import type { Project, Ctx, Scenery, RiderPt } from './scenery.ts';
import type { RoadSegment } from './road_segment.ts';
import type { World } from './world.ts';
import type { RiderState } from './rider.ts';
import { routeDistance } from './rider.ts';

// ---- dimensions (metres) ----
const LENGTH = 7;
const WIDTH = 2.4;     // narrower than the 4m lane, so it fits and rounds the corners
const HEIGHT = 3;

// ---- the chase ----
const START_AHEAD = 400;        // metres in front of the rider at the start
const SPEED_FRACTION = 0.8;     // the truck covers this fraction of the distance the rider does

// ---- colour: bright red, with a lighter roof / darker sides so the prism reads as a solid ----
const BODY = '#e0201a';
const ROOF = '#ff5a4d';
const SIDE = '#b3160f';

// a rider-frame point carrying a height off the ground
interface Pt3 { right: number; forward: number; height: number }
interface Face { pts: Pt3[]; color: string }

// The gap (metres) still ahead of the rider after he has driven `riderDist` along the route. It starts
// at START_AHEAD and closes because the truck only covers SPEED_FRACTION of his distance:
// gap = START_AHEAD - (1 - SPEED_FRACTION) * riderDist. <= 0 means we've caught it.
export function truckGap(riderDist: number): number {
  return START_AHEAD - (1 - SPEED_FRACTION) * riderDist;
}

// lower a rider-frame point onto the curved ground (the same drop the road quads use), at height `h`
// above that ground — so the whole box rides the road's fake-horizon curvature.
function lower(p: RiderPt, h: number): Pt3 {
  return { right: p.right, forward: p.forward, height: h - groundDrop(p.right, p.forward) };
}

// Build the truck as one Scenery: a box centred on the lane centre at `centerAlong` in the segment
// frame `map`. We map its four ground corners into the rider's frame, raise the roof, then paint the
// (up to) five visible faces back-to-front so the box occludes itself correctly.
function buildTruck(map: (a: number, x: number) => RiderPt, centerAlong: number, hw: number): Scenery {
  const a0 = centerAlong - LENGTH / 2, a1 = centerAlong + LENGTH / 2;   // rear (toward us), front (away)
  const xl = hw - WIDTH / 2, xr = hw + WIDTH / 2;
  const RL = map(a0, xl), RR = map(a0, xr), FL = map(a1, xl), FR = map(a1, xr);
  const g = (p: RiderPt): Pt3 => lower(p, 0);          // ground corner
  const t = (p: RiderPt): Pt3 => lower(p, HEIGHT);     // roof corner
  const faces: Face[] = [
    { color: BODY, pts: [g(RL), g(RR), t(RR), t(RL)] },   // rear (the face we chase)
    { color: BODY, pts: [g(FL), g(FR), t(FR), t(FL)] },   // front
    { color: SIDE, pts: [g(RL), g(FL), t(FL), t(RL)] },   // left
    { color: SIDE, pts: [g(RR), g(FR), t(FR), t(RR)] },   // right
    { color: ROOF, pts: [t(RL), t(RR), t(FR), t(FL)] },   // roof
  ];
  const avgF = (f: Face): number => f.pts.reduce((s, p) => s + p.forward, 0) / f.pts.length;
  const center = map(centerAlong, hw);

  const draw = (ctx: Ctx, project: Project): void => {
    for (const f of [...faces].sort((p, q) => avgF(q) - avgF(p))) {   // farthest faces first (painter's)
      const pts = clipNear(f.pts);
      if (pts.length < 3) continue;
      ctx.fillStyle = f.color;
      ctx.beginPath();
      const s0 = project(pts[0].right, pts[0].forward, pts[0].height);
      ctx.moveTo(s0.x, s0.y);
      for (let i = 1; i < pts.length; i++) {
        const s = project(pts[i].right, pts[i].forward, pts[i].height);
        ctx.lineTo(s.x, s.y);
      }
      ctx.closePath();
      ctx.fill();
    }
  };
  return { forward: center.forward, height: HEIGHT, drawAsNear: draw, drawAsFar: draw };
}

// The truck Scenery for this frame, or null if there's nothing to draw (already caught, or still
// beyond our draw distance). `chain` is the rider's look-ahead segment list and `at(d, a, x)` maps a
// point in chain[d]'s frame into the rider's frame (both from view.ts). We find which chain segment
// the truck's centre lands on by walking `gap` metres forward from the rider, then centre the box on
// that segment's lane centre.
export function truckScenery(state: RiderState, world: World, chain: RoadSegment[],
                             at: (d: number, a: number, x: number) => RiderPt): Scenery | null {
  const gap = truckGap(routeDistance(state, world));
  if (gap <= 0) return null;                       // caught — v1 leaves the rest for later
  let remaining = state.along + gap, d = 0;
  while (d < chain.length && remaining > chain[d].length) { remaining -= chain[d].length; d++; }
  if (d >= chain.length) return null;              // still beyond the look-ahead — too far to draw
  return buildTruck((a, x) => at(d, a, x), remaining, chain[d].width / 2);
}
