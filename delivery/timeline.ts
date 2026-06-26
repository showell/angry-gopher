// timeline.ts — a truck's day as one canonical sequence of timed legs.
//
// This is the single source of truth the playback reads from. A route's cost
// (solver/roadgraph) is a sum of minutes; here we lay those same minutes out in
// order and in space, so the moving dot and the checkmarks are two readings of
// ONE structure and can never drift apart. The leg durations add up to exactly
// route.time (travel + local + service); we just distribute, never invent.
//
// Legs:
//   drive   — an arterial leg along a real edge polyline (its shortest-path time)
//   arc     — a stretch of slow ring road between two doorsteps (or the gates)
//   service — the truck sitting at one house, delivering (SERVICE minutes)

import type { Pt } from "./geography.ts";
import { NEIGHBORHOODS, edgePolyline, gateAngle, houseAngles, nodeAt, ringWalkPath } from "./geography.ts";
import { SERVICE, localMinutes } from "./roadgraph.ts";
import type { Substrate } from "./roadgraph.ts";
import type { Route } from "./solver.ts";

export type Leg =
  | { kind: "drive"; pts: Pt[]; dur: number }
  | { kind: "arc"; pts: Pt[]; dur: number }
  | { kind: "service"; at: Pt; dur: number; house: string };

export type Itinerary = { legs: Leg[]; total: number };

function len(pts: Pt[]): number[] {
  const cum = [0];
  for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
  return cum;
}

/** The point at cumulative length `pos` along a polyline. */
function at(pts: Pt[], cum: number[], pos: number): Pt {
  if (pos <= 0) return pts[0];
  const total = cum[cum.length - 1];
  if (pos >= total) return pts[pts.length - 1];
  let k = 1;
  while (k < cum.length && cum[k] < pos) k++;
  const seg = cum[k] - cum[k - 1];
  const t = seg > 0 ? (pos - cum[k - 1]) / seg : 0;
  return { x: pts[k - 1].x + (pts[k].x - pts[k - 1].x) * t, y: pts[k - 1].y + (pts[k].y - pts[k - 1].y) * t };
}

/** The sub-polyline between cumulative lengths `a` and `b`, endpoints interpolated. */
function slice(pts: Pt[], cum: number[], a: number, b: number): Pt[] {
  const out: Pt[] = [at(pts, cum, a)];
  for (let k = 0; k < cum.length; k++) if (cum[k] > a && cum[k] < b) out.push(pts[k]);
  out.push(at(pts, cum, b));
  return out;
}

/** Cumulative length along the polyline where it passes closest to `target`. */
function closestPos(pts: Pt[], cum: number[], target: Pt): number {
  let best = Infinity;
  let pos = 0;
  for (let k = 1; k < pts.length; k++) {
    const ax = pts[k - 1].x;
    const ay = pts[k - 1].y;
    const dx = pts[k].x - ax;
    const dy = pts[k].y - ay;
    const l2 = dx * dx + dy * dy;
    const t = l2 > 0 ? Math.max(0, Math.min(1, ((target.x - ax) * dx + (target.y - ay) * dy) / l2)) : 0;
    const px = ax + dx * t;
    const py = ay + dy * t;
    const d = (target.x - px) ** 2 + (target.y - py) ** 2;
    if (d < best) {
      best = d;
      pos = cum[k - 1] + t * (cum[k] - cum[k - 1]);
    }
  }
  return pos;
}

/**
 * Lay the ring road of one delivery stop into legs: drive the slow arc, stopping
 * at each ordered house *where the path actually passes it*, with a SERVICE beat
 * there. `arcMin` (the ring-driving minutes) is spread across the arc by length,
 * so the leg times sum to the cost model's local time for this stop.
 */
function ringLegs(name: string, pts: Pt[], arcMin: number, houses: number[]): Leg[] {
  const cum = len(pts);
  const total = cum[cum.length - 1] || 1;
  const n = NEIGHBORHOODS.find((m) => m.name === name)!;
  const angles = houseAngles(name, houses);

  // Each house, at the cumulative length where the truck rolls past its door.
  const stops = houses
    .map((h, i) => {
      const ring = { x: n.center.x + Math.cos(angles[i]) * n.ringRadius, y: n.center.y + Math.sin(angles[i]) * n.ringRadius };
      return { house: `${name}#${h}`, pos: closestPos(pts, cum, ring) };
    })
    .sort((a, b) => a.pos - b.pos);

  const legs: Leg[] = [];
  let cursor = 0;
  const arcLeg = (a: number, b: number): void => {
    const piece = slice(pts, cum, a, b);
    if (piece.length >= 2) legs.push({ kind: "arc", pts: piece, dur: arcMin * ((b - a) / total) });
  };
  for (const s of stops) {
    arcLeg(cursor, s.pos);
    legs.push({ kind: "service", at: at(pts, cum, s.pos), dur: SERVICE, house: s.house });
    cursor = s.pos;
  }
  arcLeg(cursor, total);
  return legs;
}

/** Build a truck's whole day as one ordered, timed itinerary. */
export function buildItinerary(sub: Substrate, route: Route): Itinerary {
  const waypoints = ["FC", ...route.stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    for (const node of sub.path(waypoints[i - 1], waypoints[i])) if (nodes[nodes.length - 1] !== node) nodes.push(node);
  }

  const housesAt = new Map<string, number[]>();
  for (const s of route.stops) housesAt.set(s.nbhd, (housesAt.get(s.nbhd) ?? []).concat(s.houses));

  const delivered = new Set<string>(); // a neighborhood drives its full ring once
  const legs: Leg[] = [];
  for (let i = 1; i < nodes.length; i++) {
    const prev = nodes[i - 1];
    const node = nodes[i];
    // Adjacent nodes on a shortest path: their direct edge IS the shortest hop,
    // so sub.time(prev, node) is exactly this leg's travel time (== breakdown's).
    legs.push({ kind: "drive", pts: edgePolyline(prev, node), dur: sub.time(prev, node) });

    if (node !== "FC" && i < nodes.length - 1) {
      const entry = gateAngle(node, nodeAt(prev));
      const exit = gateAngle(node, nodeAt(nodes[i + 1]));
      // Deliver here only on the first visit; a re-thread is transit-only (the
      // little arc through, no stops) — mirrors breakdown so total == route.time.
      const full = housesAt.get(node);
      const delivering = !!(full && full.length && !delivered.has(node));
      const houses = delivering ? full! : [];
      if (delivering) delivered.add(node);
      const hAngles = houseAngles(node, houses);
      const pts = ringWalkPath(node, entry, exit, hAngles);
      const arcMin = localMinutes(node, entry, exit, hAngles);
      if (delivering) {
        for (const leg of ringLegs(node, pts, arcMin, houses)) legs.push(leg);
      } else if (pts.length >= 2) {
        legs.push({ kind: "arc", pts, dur: arcMin }); // pass-through transit arc
      }
    }
  }

  const total = legs.reduce((s, l) => s + l.dur, 0);
  return { legs, total };
}
