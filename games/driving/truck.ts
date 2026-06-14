// truck.ts — the vehicle we chase: a dark-blue truck (a box TRAILER plus a CAB in front whose nose is a
// sloped windshield) that drives the route ahead of us. It rides the CENTRE LINE of whatever segment
// it's on (no lean, no lane drift), so its body is built straight in that segment's frame and inherits
// the segment/arc heading.
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
const LENGTH = 8.4;    // trailer length (20% longer than before, for visibility)
const WIDTH = 2.4;     // narrower than the 4m lane, so it fits and rounds the corners (can't grow — road width)
const HEIGHT = 3.6;    // trailer + cab height (20% taller than before)
const CAB_LENGTH = 3.5;        // the cab sticks this far out in FRONT of the trailer
const CAB_ROOF_FRAC = 0.3;     // the cab roof is this fraction of the cab; the windshield rakes down over the rest
// tires (round, drawn flat — no depth, since we never get close enough to see it). The trailer FLOOR
// hovers just over the tire tops; the cab drops lower, its floor at the tire centre line.
const TIRE_RADIUS = 0.5;
const TRAILER_BOTTOM = 2 * TIRE_RADIUS + 0.12;   // trailer floor — just above the tire tops (a faint hover gap)
const CAB_BOTTOM = TIRE_RADIUS;                  // cab floor — at the tire's horizontal diameter (its centre)
const TIRE_PAIR_GAP = 1.2;                       // centre-to-centre within a tandem pair
const TRAILER_AXLE_INSET = 1.6;                  // each trailer tire-pair sits this far in from its end
const CAB_AXLE_FRAC = 0.55;                      // the cab's lone tire, this fraction along the cab
const TIRE_COLOR = '#15151a';                    // near-black
const TIRE_SIDES = 16;                           // polygon approximation of the circle

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

// ---- headlights: we never draw the lamps, only the two WEDGES of light they throw forward — one from each
// front corner of the cab. Each is a flat, CONSTANT-brightness wedge — we don't fade it or scale its opacity;
// its 3D ANGLE alone decides how it reads (a broad sheet when the truck is in profile, foreshortened to a
// sliver when it points away). They only appear once the sun is behind the mountains. ----
const HEADLIGHT_H = 1.0;          // height of the lamps off the road (the wedge's near edge)
const HEADLIGHT_INSET = 0.3;      // each lamp sits this far in from its cab-front corner
const CONE_FAR_H = 0.6;           // height of the wedge's far edge — close to the lamp height, so the beam points mostly FORWARD (only a gentle dip toward the road)
const CONE_LENGTH = 24;           // how far ahead the beam reaches (m)
const CONE_HALF_WIDTH = 4;        // the beam's half-spread at its far end (m)
const CONE_ALPHA = 0.85;          // each wedge's (constant) opacity — the two overlap to a brighter core
const BEAM_RGB = '255,248,214';   // warm white

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

// Build the truck as one Scenery, in the segment frame `map`: a TRAILER box hovering over its tires
// plus a lower CAB in front, and round tires at the sides. Faces are painted back-to-front so the body
// occludes itself (and its far-side tires) correctly.
function buildTruck(map: (a: number, x: number) => RiderPt, centerAlong: number, hw: number, braking: boolean, headlights: boolean): Scenery {
  const a0 = centerAlong - LENGTH / 2, a1 = centerAlong + LENGTH / 2;   // trailer rear (toward us) / front
  const a2 = a1 + CAB_LENGTH, aRoof = a1 + CAB_LENGTH * CAB_ROOF_FRAC;  // cab nose / windshield top
  const xl = hw - WIDTH / 2, xr = hw + WIDTH / 2;
  const p3 = (along: number, x: number, h: number): Pt3 => lower(map(along, x), h);   // a body point, on the curved ground

  // the two headlight wedges: one from each cab-front corner, fanning forward and dropping only gently to
  // CONE_FAR_H so they point mostly forward. Constant brightness; their projected shape (the truck's angle) is
  // what makes them read broad in profile and thin head-/tail-on.
  const wedge = (srcX: number): Pt3[] => [
    p3(a2, srcX, HEADLIGHT_H),
    p3(a2 + CONE_LENGTH, srcX - CONE_HALF_WIDTH, CONE_FAR_H),
    p3(a2 + CONE_LENGTH, srcX + CONE_HALF_WIDTH, CONE_FAR_H),
  ];
  const cones: Pt3[][] = [wedge(xl + HEADLIGHT_INSET), wedge(xr - HEADLIGHT_INSET)];

  // Each SIDE is one silhouette (trailer + cab are coplanar, so no internal faces): up the rear, along
  // the flush roof, down the windshield then the nose, back along the lower cab floor, up the step to the
  // higher trailer floor (the trailer hovers over its tires; the cab drops to the tire centre).
  const side = (x: number): Pt3[] => [
    p3(a0, x, TRAILER_BOTTOM), p3(a0, x, HEIGHT), p3(aRoof, x, HEIGHT),
    p3(a2, x, HEIGHT / 2), p3(a2, x, CAB_BOTTOM), p3(a1, x, CAB_BOTTOM), p3(a1, x, TRAILER_BOTTOM),
  ];
  const faces: Face[] = [
    { color: BODY, pts: [p3(a0, xl, TRAILER_BOTTOM), p3(a0, xr, TRAILER_BOTTOM), p3(a0, xr, HEIGHT), p3(a0, xl, HEIGHT)] },  // trailer rear (chased)
    { color: SIDE, pts: side(xl) },
    { color: SIDE, pts: side(xr) },
    { color: ROOF, pts: [p3(a0, xl, HEIGHT), p3(a0, xr, HEIGHT), p3(aRoof, xr, HEIGHT), p3(aRoof, xl, HEIGHT)] },            // flush roof
    { color: BODY, pts: [p3(aRoof, xl, HEIGHT), p3(aRoof, xr, HEIGHT), p3(a2, xr, HEIGHT / 2), p3(a2, xl, HEIGHT / 2)] },    // windshield (not glass yet)
    { color: BODY, pts: [p3(a2, xl, HEIGHT / 2), p3(a2, xr, HEIGHT / 2), p3(a2, xr, CAB_BOTTOM), p3(a2, xl, CAB_BOTTOM)] },  // cab nose
  ];

  // tires: a flat circle in each side plane (no depth). 4 per side on the trailer — a tandem pair inset
  // from each end — plus one per side under the cab. They join the face sort, so the body occludes their
  // tops and the lower arcs poke out below the floor.
  const tire = (alongC: number, x: number): Face => {
    const pts: Pt3[] = [];
    for (let i = 0; i < TIRE_SIDES; i++) {
      const th = (i / TIRE_SIDES) * 2 * Math.PI;
      pts.push(p3(alongC + TIRE_RADIUS * Math.cos(th), x, TIRE_RADIUS + TIRE_RADIUS * Math.sin(th)));
    }
    return { color: TIRE_COLOR, pts };
  };
  const rearAxle = a0 + TRAILER_AXLE_INSET, frontAxle = a1 - TRAILER_AXLE_INSET, cabAxle = a1 + CAB_LENGTH * CAB_AXLE_FRAC;
  const axles = [rearAxle - TIRE_PAIR_GAP / 2, rearAxle + TIRE_PAIR_GAP / 2,
                 frontAxle - TIRE_PAIR_GAP / 2, frontAxle + TIRE_PAIR_GAP / 2, cabAxle];
  for (const x of [xl, xr]) for (const a of axles) faces.push(tire(a, x));

  const avgF = (f: Face): number => f.pts.reduce((s, p) => s + p.forward, 0) / f.pts.length;
  const center = map(centerAlong, hw);

  // the two brake lights, a panel low on the trailer rear (now that the rear face starts at TRAILER_BOTTOM).
  const rearPanel = (xA: number, xB: number, hLo: number, hHi: number): Pt3[] =>
    [lower(map(a0, xA), hLo), lower(map(a0, xB), hLo), lower(map(a0, xB), hHi), lower(map(a0, xA), hHi)];
  const BL = TRAILER_BOTTOM + 0.20 * (HEIGHT - TRAILER_BOTTOM), BH = TRAILER_BOTTOM + 0.50 * (HEIGHT - TRAILER_BOTTOM);
  const brakeLights: Pt3[][] = [
    rearPanel(xl + 0.10 * WIDTH, xl + 0.36 * WIDTH, BL, BH),   // left light
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
    if (headlights) { ctx.fillStyle = `rgba(${BEAM_RGB},${CONE_ALPHA})`; for (const c of cones) fill(ctx, project, c); }   // headlight wedges under the body
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
                             at: (d: number, a: number, x: number) => RiderPt, headlights: boolean): Scenery | null {
  const lead = truck.pos - routeDistance(rider, world);
  if (lead <= 0) return null;                       // caught (shouldn't happen — the schedule keeps it ahead)
  let remaining = rider.along + lead, d = 0;
  while (d < chain.length && remaining > chain[d].length) { remaining -= chain[d].length; d++; }
  if (d >= chain.length) return null;               // still beyond the look-ahead — too far to draw
  return buildTruck((a, x) => at(d, a, x), remaining, chain[d].width / 2, truck.braking, headlights);
}
