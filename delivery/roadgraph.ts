// roadgraph.ts — the routing substrate. Builds the artery graph from the
// geography, weights each edge with a V1 travel-time model, and computes
// all-pairs shortest times between every neighborhood and the warehouse (FC).
//
// Cost model — three pieces, deliberately simple and tunable:
//
//   1. TRAVEL — an edge's time = its drawn length (px) * a region speed factor
//      * MIN_PER_PX. Westside city streets are slow, the Eastside normal, the
//      Issaquah<->Redmond bypass fast, bridges a drag (lake crossings). Travel
//      between two neighborhoods = shortest path over this graph. Arteries are
//      the FAST part — this is the "painful to GET TO" half.
//
//   2. LOCAL — the ring driving *inside* a neighborhood: the arc you cover
//      entering at one gate, touching your ordered houses, and leaving at
//      another. Neighborhood streets are SLOW — NEIGHBORHOOD_SLOWDOWN× the local
//      arteries (residential speed limits). There's no flat "enter" charge; the
//      cost of a neighborhood is that you're *in* it, driving its slow ring. A
//      neighborhood merely threaded on the way through still pays its short
//      gate-to-gate arc (the "little arc to get through Downtown"). This slow
//      ring is also what deters two trucks from both working one neighborhood.
//
//   3. SERVICE — a small uniform beat per order actually delivered (the truck
//      stopping at the door). Nearly constant across trucks, so it barely tilts
//      the routing; it's mostly there to feel real in playback.

import type { Pt } from "./geography.ts";
import { NEIGHBORHOODS, ROADS, BRIDGES, roadGates, bridgeSegments, ringWalkArcPx } from "./geography.ts";

export const MIN_PER_PX = 0.06;
export const SPEED = { city: 1.6, suburb: 1.0, bridge: 1.2, fast: 0.6 };
export const NEIGHBORHOOD_SLOWDOWN = 2.1; // ring roads are this much slower than the local arteries
export const SERVICE = 2; // minutes per order delivered, identical everywhere

/** Service nodes: every neighborhood, plus the warehouse depot. */
export const NODES: string[] = [...NEIGHBORHOODS.map((n) => n.name), "FC"];

function len(pts: Pt[]): number {
  let d = 0;
  for (let i = 1; i < pts.length; i++) d += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
  return d;
}

function isWest(name: string): boolean {
  return NEIGHBORHOODS.some((n) => n.name === name && n.side === "west");
}

/** Speed multiplier for an edge (lower = faster). The geography's texture lives here. */
function factor(a: string, b: string, bridge: boolean): number {
  if ((a === "Issaquah" && b === "Redmond") || (a === "Redmond" && b === "Issaquah")) return SPEED.fast;
  if (bridge) return SPEED.bridge;
  if (isWest(a) || isWest(b)) return SPEED.city;
  return SPEED.suburb;
}

/**
 * Minutes a truck spends *inside* a neighborhood, driving its slow ring road:
 * the arc to enter at `entryA`, touch the ordered houses, and leave at `exitA`
 * (zero houses = a pass-through, which still costs the short arc between the two
 * gates). Residential streets run NEIGHBORHOOD_SLOWDOWN× slower than the local
 * arteries (Westside city, everywhere else normal). SERVICE (per-order time at
 * the door) is added separately by the caller.
 */
export function localMinutes(name: string, entryA: number, exitA: number, houseAngles: number[]): number {
  const arterial = isWest(name) ? SPEED.city : SPEED.suburb;
  return ringWalkArcPx(name, entryA, exitA, houseAngles) * arterial * NEIGHBORHOOD_SLOWDOWN * MIN_PER_PX;
}

export type Edge = { a: string; b: string; minutes: number };

/** Every artery edge (surface roads + bridge segments) with its travel time. */
export function edges(): Edge[] {
  const out: Edge[] = [];
  for (const r of ROADS) {
    out.push({ a: r[0], b: r[1], minutes: len(roadGates(r)) * factor(r[0], r[1], false) * MIN_PER_PX });
  }
  for (const b of BRIDGES) {
    for (const seg of bridgeSegments(b)) {
      const [x, y] = seg.edge;
      out.push({ a: x, b: y, minutes: len(seg.pts) * factor(x, y, true) * MIN_PER_PX });
    }
  }
  return out;
}

export type Substrate = {
  nodes: string[];
  index: Map<string, number>;
  matrix: number[][]; // all-pairs shortest travel minutes
  time: (a: string, b: string) => number;
  /** The node sequence of the shortest path from `a` to `b`, both ends inclusive. */
  path: (a: string, b: string) => string[];
};

/** Build the graph and compute all-pairs shortest travel times (Dijkstra per source). */
export function buildSubstrate(): Substrate {
  const nodes = NODES;
  const index = new Map(nodes.map((n, i) => [n, i]));
  const N = nodes.length;

  const adj: { to: number; w: number }[][] = nodes.map(() => []);
  for (const e of edges()) {
    const i = index.get(e.a);
    const j = index.get(e.b);
    if (i === undefined || j === undefined) throw new Error(`edge names off the node list: ${e.a}-${e.b}`);
    adj[i].push({ to: j, w: e.minutes });
    adj[j].push({ to: i, w: e.minutes });
  }

  const matrix = nodes.map(() => new Array<number>(N).fill(Infinity));
  // prev[s][v] = the node before v on the shortest path from s (−1 = none/source).
  const prev = nodes.map(() => new Array<number>(N).fill(-1));
  for (let s = 0; s < N; s++) {
    const dist = matrix[s];
    const back = prev[s];
    dist[s] = 0;
    const done = new Array<boolean>(N).fill(false);
    for (let it = 0; it < N; it++) {
      let u = -1;
      let best = Infinity;
      for (let k = 0; k < N; k++) if (!done[k] && dist[k] < best) {
        best = dist[k];
        u = k;
      }
      if (u === -1) break;
      done[u] = true;
      for (const { to, w } of adj[u]) if (dist[u] + w < dist[to]) {
        dist[to] = dist[u] + w;
        back[to] = u;
      }
    }
  }

  const idOf = (name: string): number => {
    const i = index.get(name);
    if (i === undefined) throw new Error(`unknown node: ${name}`);
    return i;
  };

  const time = (a: string, b: string): number => matrix[idOf(a)][idOf(b)];

  const path = (a: string, b: string): string[] => {
    const s = idOf(a);
    let v = idOf(b);
    if (!Number.isFinite(matrix[s][v])) throw new Error(`no path: ${a} -> ${b}`);
    const rev: number[] = [];
    while (v !== s) {
      rev.push(v);
      v = prev[s][v];
      if (v === -1) throw new Error(`broken path chain: ${a} -> ${b}`);
    }
    rev.push(s);
    return rev.reverse().map((i) => nodes[i]);
  };

  return { nodes, index, matrix, time, path };
}
