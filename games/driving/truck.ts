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
//   • approaching a turn it BRAKES, then accelerates back out the far side (behind schedule again).
// Its HABITS mirror the rider's so the chase doesn't oscillate wildly: it brakes over the same distance
// (TRUCK_BRAKE_DISTANCE = the rider's APPROACH_INTERSECTION_DIST) and aims for the same angle-dependent
// safe turn speed, just scaled down by TRUCK_TURN_CAUTION (a truck rounds corners more carefully). The
// braking is kinematic (a = (vEnd^2 - v^2)/2d), the way the rider brakes. Its one ADVANTAGE is on the
// straights: when behind schedule it claws back at 1.1x the rider's acceleration, so it can hold its
// lead. Bright-red brake lights light up on its rear ONLY while it's actually slowing.
//
// It obeys the same ground-curvature + near-plane rules as the road it sits on.

import { groundDrop, clipNear } from './scenery.ts';
import type { Project, Ctx, Scenery, RiderPt } from './scenery.ts';
import type { World } from './world.ts';
import type { RoadSegment } from './road_segment.ts';
import type { RiderState } from './rider.ts';
import { routeDistance, A_ACCEL, V_BASE, V_MAX, APPROACH_INTERSECTION_DIST } from './rider.ts';
import { turnSpeed } from './intersection.ts';

// ---- dimensions (metres) ----
const LENGTH = 7;
const WIDTH = 2.4;     // narrower than the 4m lane, so it fits and rounds the corners
const HEIGHT = 3;

// ---- the chase ----
const START_AHEAD = 500;            // metres in front of the rider at the start (the initial lead)
const FINISH_LEAD = 100;            // the lead the schedule lerps DOWN to by the course end — not 0,
                                    // because braking for the final corner would dip a near-0 lead
                                    // negative and we'd catch it at the line; 100m keeps a photo finish
const TRUCK_TURN_CAUTION = 0.8;        // takes each corner at this fraction of the rider's safe turn speed —
                                       // a truck is more conservative through turns than a nimble rider
const TRUCK_BRAKE_DISTANCE = APPROACH_INTERSECTION_DIST;   // brake over the SAME distance the rider does — same stopping habit
const TRUCK_CHASE_ACCEL = 1.1 * A_ACCEL;   // behind-schedule acceleration — 10% FASTER than the rider, to claw the lead back
const TRUCK_MAX_V = 1.1 * V_MAX;           // top speed — 10% over the rider's, its straightaway edge, but bounded

// ---- colour: a dark-blue body (lighter roof / darker sides so the prism reads as a solid), plus
// bright-red brake lights that only light while it slows. ----
const BODY = '#1c2e66';
const ROOF = '#3a52a8';
const SIDE = '#152150';
const BRAKE = '#ff2a18';

// a rider-frame point carrying a height off the ground
interface Pt3 { right: number; forward: number; height: number }
interface Face { pts: Pt3[]; color: string }

// The truck's own state: how far it has driven along the route, its speed, and whether it's slowing
// this frame (brake lights show only then).
export interface TruckState { pos: number; v: number; braking: boolean }

// The total length of the course — the sum of the segment lengths (intersection arcs ignored as
// negligible). The schedule lerps the truck's lead to ~0 over this distance.
export function courseLength(world: World): number {
  let L = 0;
  for (const id of world.order) L += world.segments[id].length;
  return L;
}

// The truck at the start: START_AHEAD down the road, idling at the base speed, not braking.
export function initialTruck(): TruckState {
  return { pos: START_AHEAD, v: V_BASE, braking: false };
}

// The next real TURN ahead of `pos`: how far to it, and the rider's safe speed for it. A terminus is
// not a turn (you don't brake to round the finish line), so it returns {Infinity, 0} there and past the
// course end.
function nextTurn(pos: number, world: World): { dist: number; vTurn: number } {
  let cum = 0;
  for (const id of world.order) {
    cum += world.segments[id].length;
    if (pos < cum) {
      const ixn = world.intersections[world.segments[id].exitIxn];
      return ixn.to === null ? { dist: Infinity, vTurn: 0 } : { dist: cum - pos, vTurn: turnSpeed(ixn) };
    }
  }
  return { dist: Infinity, vTurn: 0 };
}

// Advance the truck one rider-frame. `riderDist` is how far the rider has now driven (its schedule is
// anchored to that). Pure: (TruckState, riderDist, world, L) -> the next TruckState.
export function nextTruck(truck: TruckState, riderDist: number, world: World, L: number): TruckState {
  const scheduled = riderDist + FINISH_LEAD + (START_AHEAD - FINISH_LEAD) * (1 - riderDist / L);   // where the truck "should" be by now
  const { dist: distToTurn, vTurn } = nextTurn(truck.pos, world);
  const turnTarget = vTurn * TRUCK_TURN_CAUTION;             // the speed it aims to hit the corner at
  let v = truck.v;
  let braking = false;
  if (distToTurn <= TRUCK_BRAKE_DISTANCE) {
    // brake at exactly the rate that arrives at the turn at turnTarget (kinematic, the way the rider
    // brakes: a = (vEnd^2 - v^2) / 2d), recomputed each frame as the gap closes.
    const a = distToTurn > 1e-6 ? (turnTarget * turnTarget - v * v) / (2 * distToTurn) : 0;
    v = Math.max(turnTarget, v + a);
    braking = v < truck.v;                                   // lit only while actually slowing
  } else if (truck.pos < scheduled) {
    v = Math.min(TRUCK_MAX_V, v + TRUCK_CHASE_ACCEL);        // behind schedule: accelerate, capped at its top speed
  }                                                          // ahead of schedule, not braking: cruise (hold v)
  // Three rules, nothing else: brake before a turn / accelerate when behind schedule / cruise when
  // ahead. The truck's speed is NEVER tied to the rider's — only to those rules. (`scheduled` reads the
  // rider's DISTANCE to know where the truck should be, but never the rider's speed.)
  return { pos: truck.pos + v, v, braking };
}

// lower a rider-frame point onto the curved ground (the same drop the road quads use), at height `h`
// above that ground — so the whole box rides the road's fake-horizon curvature.
function lower(p: RiderPt, h: number): Pt3 {
  return { right: p.right, forward: p.forward, height: h - groundDrop(p.right, p.forward) };
}

// Build the truck as one Scenery: a box centred on the lane centre at `centerAlong` in the segment
// frame `map`. We map its four ground corners into the rider's frame, raise the roof, then paint the
// (up to) five visible faces back-to-front so the box occludes itself correctly.
function buildTruck(map: (a: number, x: number) => RiderPt, centerAlong: number, hw: number, braking: boolean): Scenery {
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

  // a small panel on the REAR face (along a0), in [across, height] fractions of the body — the two
  // brake lights live here. Built lazily, drawn only when slowing.
  const rearPanel = (xA: number, xB: number, hLo: number, hHi: number): Pt3[] =>
    [lower(map(a0, xA), hLo), lower(map(a0, xB), hLo), lower(map(a0, xB), hHi), lower(map(a0, xA), hHi)];
  const BL = 0.26 * HEIGHT, BH = 0.60 * HEIGHT;   // brake-light height band (taller than before — bigger lights)
  const brakeLights: Pt3[][] = [
    rearPanel(xl + 0.10 * WIDTH, xl + 0.36 * WIDTH, BL, BH),   // left light (wider, too)
    rearPanel(xr - 0.36 * WIDTH, xr - 0.10 * WIDTH, BL, BH),   // right light
  ];

  const fill = (ctx: Ctx, project: Project, poly: Pt3[]): void => {
    const pts = clipNear(poly);
    if (pts.length < 3) return;
    ctx.beginPath();
    const s0 = project(pts[0].right, pts[0].forward, pts[0].height);
    ctx.moveTo(s0.x, s0.y);
    for (let i = 1; i < pts.length; i++) {
      const s = project(pts[i].right, pts[i].forward, pts[i].height);
      ctx.lineTo(s.x, s.y);
    }
    ctx.closePath();
    ctx.fill();
  };

  // a soft red halo around a brake light: project its corners, find their screen centre + radius, and
  // lay down a radial gradient a few times that size — so the light reads as GLOWING, not just a patch.
  const glow = (ctx: Ctx, project: Project, poly: Pt3[]): void => {
    const pts = clipNear(poly);
    if (pts.length < 3) return;
    const sp = pts.map((p) => project(p.right, p.forward, p.height));
    let cx = 0, cy = 0;
    for (const s of sp) { cx += s.x; cy += s.y; }
    cx /= sp.length; cy /= sp.length;
    let r = 0;
    for (const s of sp) r = Math.max(r, Math.hypot(s.x - cx, s.y - cy));
    const halo = ctx.createRadialGradient(cx, cy, 0, cx, cy, r * 3.2);
    halo.addColorStop(0, 'rgba(255,80,60,0.9)');
    halo.addColorStop(0.45, 'rgba(255,42,24,0.45)');
    halo.addColorStop(1, 'rgba(255,42,24,0)');
    ctx.fillStyle = halo;
    ctx.beginPath();
    ctx.arc(cx, cy, r * 3.2, 0, 2 * Math.PI);
    ctx.fill();
  };

  const draw = (ctx: Ctx, project: Project): void => {
    for (const f of [...faces].sort((p, q) => avgF(q) - avgF(p))) {   // farthest faces first (painter's)
      ctx.fillStyle = f.color;
      fill(ctx, project, f.pts);
    }
    if (braking) {   // the rear face is the nearest, drawn last above — so the lights land on top of it
      for (const light of brakeLights) glow(ctx, project, light);   // soft halo first…
      ctx.fillStyle = BRAKE;
      for (const light of brakeLights) fill(ctx, project, light);   // …then the bright core on top
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
  return buildTruck((a, x) => at(d, a, x), remaining, chain[d].width / 2, truck.braking);
}
