// roadgraph.ts — the routing substrate. Builds the artery graph from the
// geography, weights each edge with a V1 travel-time model, and computes
// all-pairs shortest times between every neighborhood and the warehouse (FC).
//
// V1 cost model — three pieces, deliberately simple and tunable:
//
//   1. TRAVEL — an edge's time = its drawn length (px) * a region speed factor
//      * MIN_PER_PX. Westside city streets are slow, the Eastside normal, the
//      Issaquah<->Redmond bypass fast, bridges a touch quick (highways). Travel
//      between two neighborhoods = shortest path over this graph. This is the
//      "painful to GET TO" half.
//
//   2. RING — a FIXED cost paid every time a truck enters a neighborhood, no
//      matter how many orders it has there. This is the "painful once you're IN
//      it" half, and it's identical for every neighborhood (per Steve's "same
//      cost once you're in it"). Its real job: make it egregious for two trucks
//      to hit the same neighborhood — each pays RING + its own access travel. So
//      the solver consolidates a neighborhood onto one truck... unless capacity
//      forces a split (a neighborhood with more orders than a truck's spare
//      totes MUST be split, and the math accepts the double RING).
//
//   3. SERVICE — a small uniform cost per order actually delivered.
//
// We left the get-to/once-in balance explicit (TRAVEL vs RING) precisely so we
// can shift weight between them as we iterate.

import type { Pt } from "./geography.ts";
import { NEIGHBORHOODS, ROADS, BRIDGES, roadGates, bridgeSegments } from "./geography.ts";

export const MIN_PER_PX = 0.06;
export const SPEED = { city: 1.6, suburb: 1.0, bridge: 0.9, fast: 0.5 };
export const RING = 15; // fixed minutes to commit a truck to a neighborhood (once)
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
  for (let s = 0; s < N; s++) {
    const dist = matrix[s];
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
      for (const { to, w } of adj[u]) if (dist[u] + w < dist[to]) dist[to] = dist[u] + w;
    }
  }

  const time = (a: string, b: string): number => {
    const i = index.get(a);
    const j = index.get(b);
    if (i === undefined || j === undefined) throw new Error(`unknown node: ${a} or ${b}`);
    return matrix[i][j];
  };

  return { nodes, index, matrix, time };
}
