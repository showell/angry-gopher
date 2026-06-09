// truck.ts — the vehicle we chase: a bright red rectangular prism that drives the route ahead of us.
// It rides the CENTRE LINE of whatever segment it's on (no lean, no lane drift), so its box is built
// straight in that segment's frame and inherits the segment/arc heading.
//
// MOTION (a tiny simulation of its own, advanced one step per rider frame and kept in a history
// alongside the rider's so it scrubs cleanly on pause/reverse):
//   • it keeps to a SCHEDULE — its lead over the rider lerps from START_AHEAD down to FINISH_LEAD
//     across the whole course (length precomputed, intersection arcs ignored as negligible), so the
//     chase tightens toward a photo finish (a small finish lead, not 0, so the last corner's braking
//     can't dip it negative);
//   • when it's BEHIND schedule it floors the throttle (accelerates, no speed cap) until it's back on
//     pace, no matter how fast the rider is going; when it's AHEAD of schedule on a straight it just
//     cruises (holds speed);
//   • approaching a turn it BRAKES down toward TRUCK_TURN_SPEED within TRUCK_BRAKE_DISTANCE, then
//     accelerates back out the far side (it's behind schedule again after the corner).
// Its acceleration is 0.9x the rider's (A_ACCEL), the one knob that makes the pacing work out.
//
// It obeys the same ground-curvature + near-plane rules as the road it sits on.

import { groundDrop, clipNear } from './scenery.ts';
import type { Project, Ctx, Scenery, RiderPt } from './scenery.ts';
import type { World } from './world.ts';
import type { RoadSegment } from './road_segment.ts';
import type { RiderState } from './rider.ts';
import { routeDistance, A_ACCEL, V_BASE } from './rider.ts';

// ---- dimensions (metres) ----
const LENGTH = 7;
const WIDTH = 2.4;     // narrower than the 4m lane, so it fits and rounds the corners
const HEIGHT = 3;

// ---- the chase ----
const START_AHEAD = 800;            // metres in front of the rider at the start (the initial lead)
const FINISH_LEAD = 100;            // the lead the schedule lerps DOWN to by the course end — not 0,
                                    // because braking for the final corner would dip a near-0 lead
                                    // negative and we'd catch it at the line; 100m keeps a photo finish
const TRUCK_TURN_SPEED = 0.3;       // m/press it slows to for a corner
const TRUCK_BRAKE_DISTANCE = 100;   // metres before a turn it starts braking
const TRUCK_ACCEL = 0.9 * A_ACCEL;  // 0.9x the rider's acceleration — accelerating AND braking rate

// ---- colour: bright red, with a lighter roof / darker sides so the prism reads as a solid ----
const BODY = '#e0201a';
const ROOF = '#ff5a4d';
const SIDE = '#b3160f';

// a rider-frame point carrying a height off the ground
interface Pt3 { right: number; forward: number; height: number }
interface Face { pts: Pt3[]; color: string }

// The truck's own state: how far it has driven along the route, and its speed.
export interface TruckState { pos: number; v: number }

// The total length of the course — the sum of the segment lengths (intersection arcs ignored as
// negligible). The schedule lerps the truck's lead to ~0 over this distance.
export function courseLength(world: World): number {
  let L = 0;
  for (const id of world.order) L += world.segments[id].length;
  return L;
}

// The truck at the start: START_AHEAD down the road, idling at the base speed.
export function initialTruck(): TruckState {
  return { pos: START_AHEAD, v: V_BASE };
}

// Metres from `pos` to the next real TURN ahead (a terminus is not a turn — you don't brake to round
// the finish line, so it returns Infinity there and on anything past the course end).
function distToNextTurn(pos: number, world: World): number {
  let cum = 0;
  for (const id of world.order) {
    cum += world.segments[id].length;
    if (pos < cum) {
      const ixn = world.intersections[world.segments[id].exitIxn];
      return ixn.to === null ? Infinity : cum - pos;
    }
  }
  return Infinity;
}

// Advance the truck one rider-frame. `riderDist` is how far the rider has now driven (its schedule is
// anchored to that). Pure: (TruckState, riderDist, world, L) -> the next TruckState.
export function nextTruck(truck: TruckState, riderDist: number, world: World, L: number): TruckState {
  const scheduled = riderDist + FINISH_LEAD + (START_AHEAD - FINISH_LEAD) * (1 - riderDist / L);   // where the truck "should" be by now
  const distToTurn = distToNextTurn(truck.pos, world);
  let v = truck.v;
  if (distToTurn <= TRUCK_BRAKE_DISTANCE) {
    v = Math.max(TRUCK_TURN_SPEED, v - TRUCK_ACCEL);   // brake into the corner, hold ~TRUCK_TURN_SPEED through it
  } else if (truck.pos < scheduled) {
    v = v + TRUCK_ACCEL;                               // behind schedule: floor it (no speed cap)
  }                                                    // else ahead of schedule on a straight: cruise (hold v)
  return { pos: truck.pos + v, v };
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

// The truck Scenery for this frame, or null if there's nothing to draw (caught, or still beyond our
// draw distance). `chain` is the rider's look-ahead segment list and `at(d, a, x)` maps a point in
// chain[d]'s frame into the rider's frame (both from view.ts). We find which chain segment the truck's
// centre lands on by walking its LEAD (pos minus how far the rider has driven) forward from the rider.
export function truckScenery(truck: TruckState, rider: RiderState, world: World, chain: RoadSegment[],
                             at: (d: number, a: number, x: number) => RiderPt): Scenery | null {
  const lead = truck.pos - routeDistance(rider, world);
  if (lead <= 0) return null;                       // caught (shouldn't happen — the schedule keeps it ahead)
  let remaining = rider.along + lead, d = 0;
  while (d < chain.length && remaining > chain[d].length) { remaining -= chain[d].length; d++; }
  if (d >= chain.length) return null;               // still beyond the look-ahead — too far to draw
  return buildTruck((a, x) => at(d, a, x), remaining, chain[d].width / 2);
}
