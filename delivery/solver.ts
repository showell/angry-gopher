// solver.ts — the routing brain. Given the day's orders (which houses ordered,
// grouped by neighborhood) and the travel substrate, it assigns neighborhoods to
// trucks and orders each truck's stops to minimize TOTAL driver time. Pure: no
// DOM. The map just draws what this returns.
//
// A truck's time has three parts, all of which the solver now feels:
//
//   1. TRAVEL — artery time between stops (the substrate's shortest paths).
//   2. LOCAL  — time spent *inside* each neighborhood it touches: a small ENTER
//      overhead plus the ring driving to reach its ordered houses, entering at
//      the gate facing where it came from and leaving at the gate facing where
//      it's headed (see geography.ringWalk). A neighborhood merely *threaded*
//      on the way through still costs the short arc between its two gates.
//   3. SERVICE — per-order time at each door.
//
// LOCAL depends on the entry/exit gates, so it depends on the route's *shape* —
// which means reordering a route, or which truck takes a neighborhood, changes
// the cost. The old flat per-visit RING is gone; the geometry now does the
// consolidation-deterrence (two trucks each pay their own ENTER + ring arc).
//
// Construction is Clarke–Wright savings (greedy best-merge); improvement is
// 2-opt within a route and Or-opt across routes. Every accepted move records a
// "saved N min" reason, for the manager-override phase to surface later.

import { FLEET, gateAngle, houseAngles, nodeAt } from "./geography.ts";
import { SERVICE, localMinutes } from "./roadgraph.ts";
import type { Substrate } from "./roadgraph.ts";

export type Stop = { nbhd: string; orders: number; houses: number[] }; // ordered house indices

export type Route = {
  stops: Stop[]; // ordered neighborhoods this truck visits (FC is implicit at both ends)
  orders: number; // totes carried (<= capacity)
  travel: number; // artery time between stops
  time: number; // travel + local + service (this truck's slice of the total)
};

export type Move = { kind: "merge" | "2-opt" | "or-opt"; saved: number; detail: string };

export type Plan = {
  routes: Route[];
  totalTime: number;
  travel: number; // total artery time across the fleet
  local: number; // total in-neighborhood driving + ENTER overhead
  service: number; // total per-order time (a constant for a given day)
  log: Move[];
  unrouted: Stop[]; // demand that didn't fit the fleet (should be empty; surfaced if not)
};

const CAP = FLEET.totesPerTruck;

function loadOf(stops: Stop[]): number {
  return stops.reduce((s, c) => s + c.orders, 0);
}

/** Houses ordered at each neighborhood for one route (so the cost knows the ring arc). */
function housesByNbhd(stops: Stop[]): Map<string, number[]> {
  const m = new Map<string, number[]>();
  for (const s of stops) m.set(s.nbhd, (m.get(s.nbhd) ?? []).concat(s.houses));
  return m;
}

type Breakdown = { travel: number; local: number; service: number; time: number };

/**
 * Full cost of a stop sequence. Expands the shortest path so every neighborhood
 * the truck actually drives through (delivered-to OR threaded) is priced with
 * the correct entry/exit gates.
 */
function breakdown(sub: Substrate, stops: Stop[]): Breakdown {
  if (stops.length === 0) return { travel: 0, local: 0, service: 0, time: 0 };

  const waypoints = ["FC", ...stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    for (const node of sub.path(waypoints[i - 1], waypoints[i])) {
      if (nodes[nodes.length - 1] !== node) nodes.push(node);
    }
  }

  const houses = housesByNbhd(stops);
  let travel = 0;
  for (let i = 1; i < nodes.length; i++) travel += sub.time(nodes[i - 1], nodes[i]);

  let local = 0;
  for (let i = 1; i < nodes.length - 1; i++) {
    const node = nodes[i];
    if (node === "FC") continue;
    const entry = gateAngle(node, nodeAt(nodes[i - 1]));
    const exit = gateAngle(node, nodeAt(nodes[i + 1]));
    local += localMinutes(node, entry, exit, houseAngles(node, houses.get(node) ?? []));
  }

  const service = loadOf(stops) * SERVICE;
  return { travel, local, service, time: travel + local + service };
}

const costOf = (sub: Substrate, stops: Stop[]): number => breakdown(sub, stops).time;

/** Public cost of an arbitrary stop sequence — for checks and the manager-override phase. */
export function routeTime(sub: Substrate, stops: Stop[]): number {
  return breakdown(sub, stops).time;
}

/** Lay routes a and b end-to-end the cheapest of four ways (either may flip). */
function bestJoin(sub: Substrate, a: Stop[], b: Stop[]): Stop[] {
  const ra = [...a].reverse();
  const rb = [...b].reverse();
  const options = [
    [...a, ...b],
    [...a, ...rb],
    [...ra, ...b],
    [...ra, ...rb],
  ];
  let best = options[0];
  let bestT = Infinity;
  for (const o of options) {
    const t = costOf(sub, o);
    if (t < bestT) {
      bestT = t;
      best = o;
    }
  }
  return best;
}

/** Orders map -> customers. One per neighborhood; a forced split when demand > capacity. */
function customers(orders: Map<string, number[]>): Stop[] {
  const out: Stop[] = [];
  for (const [nbhd, idx] of orders) {
    for (let i = 0; i < idx.length; i += CAP) {
      const houses = idx.slice(i, i + CAP);
      out.push({ nbhd, orders: houses.length, houses });
    }
  }
  return out;
}

/** Greedy Clarke–Wright: repeatedly merge the two routes that save the most total time. */
function construct(sub: Substrate, routes: Stop[][], log: Move[], force: boolean): void {
  for (;;) {
    let best: { i: number; j: number; merged: Stop[]; saved: number } | null = null;
    for (let i = 0; i < routes.length; i++) {
      for (let j = i + 1; j < routes.length; j++) {
        if (loadOf(routes[i]) + loadOf(routes[j]) > CAP) continue;
        const merged = bestJoin(sub, routes[i], routes[j]);
        const saved = costOf(sub, routes[i]) + costOf(sub, routes[j]) - costOf(sub, merged);
        if (!best || saved > best.saved) best = { i, j, merged, saved };
      }
    }
    if (!best) break; // nothing fits — capacity-stuck
    if (!force && best.saved <= 1e-9) break; // no further win
    if (force && routes.length <= FLEET.trucks) break; // fleet now fits
    log.push({ kind: "merge", saved: best.saved, detail: `${best.merged.map((s) => s.nbhd).join(" · ")}` });
    routes[best.i] = best.merged;
    routes.splice(best.j, 1);
  }
}

/** 2-opt: reverse a sub-segment of one route while it keeps cutting cost. */
function twoOpt(sub: Substrate, stops: Stop[], log: Move[]): void {
  let improved = true;
  while (improved) {
    improved = false;
    for (let i = 0; i < stops.length - 1; i++) {
      for (let k = i + 1; k < stops.length; k++) {
        const before = costOf(sub, stops);
        const candidate = [...stops.slice(0, i), ...stops.slice(i, k + 1).reverse(), ...stops.slice(k + 1)];
        const saved = before - costOf(sub, candidate);
        if (saved > 1e-9) {
          stops.splice(0, stops.length, ...candidate);
          log.push({ kind: "2-opt", saved, detail: `reordered ${stops.map((s) => s.nbhd).join(" · ")}` });
          improved = true;
        }
      }
    }
  }
}

/** Or-opt: relocate one stop to the best slot in any route (capacity permitting). */
function orOpt(sub: Substrate, routes: Stop[][], log: Move[]): void {
  let improved = true;
  while (improved) {
    improved = false;
    for (let r = 0; r < routes.length; r++) {
      for (let s = 0; s < routes[r].length; s++) {
        const stop = routes[r][s];
        const without = [...routes[r].slice(0, s), ...routes[r].slice(s + 1)];
        const drop = costOf(sub, routes[r]) - costOf(sub, without);

        let best: { t: number; pos: number; gain: number } | null = null;
        for (let t = 0; t < routes.length; t++) {
          if (t === r) continue;
          if (loadOf(routes[t]) + stop.orders > CAP) continue;
          const baseT = costOf(sub, routes[t]);
          for (let pos = 0; pos <= routes[t].length; pos++) {
            const into = [...routes[t].slice(0, pos), stop, ...routes[t].slice(pos)];
            const gain = drop - (costOf(sub, into) - baseT);
            if (gain > 1e-9 && (!best || gain > best.gain)) best = { t, pos, gain };
          }
        }

        if (best) {
          routes[r] = without;
          routes[best.t] = [...routes[best.t].slice(0, best.pos), stop, ...routes[best.t].slice(best.pos)];
          log.push({ kind: "or-opt", saved: best.gain, detail: `moved ${stop.nbhd} to another truck` });
          improved = true;
        }
      }
    }
    if (improved) routes.splice(0, routes.length, ...routes.filter((r) => r.length > 0)); // drop emptied trucks
  }
}

/** Plan the fleet for a day's orders. Deterministic — same orders, same plan. */
export function solve(sub: Substrate, orders: Map<string, number[]>): Plan {
  const log: Move[] = [];
  const routes: Stop[][] = customers(orders).map((c) => [c]);

  construct(sub, routes, log, false); // savings merges while they help
  if (routes.length > FLEET.trucks) construct(sub, routes, log, true); // squeeze into the fleet

  for (const r of routes) twoOpt(sub, r, log);
  orOpt(sub, routes, log);
  for (const r of routes) twoOpt(sub, r, log); // re-tidy after relocations

  const unrouted: Stop[] = [];
  while (routes.length > FLEET.trucks) unrouted.push(...routes.pop()!);

  const built: Route[] = routes
    .filter((r) => r.length > 0)
    .map((stops) => {
      const b = breakdown(sub, stops);
      return { stops, orders: loadOf(stops), travel: b.travel, time: b.time };
    })
    .sort((a, b) => b.orders - a.orders);

  const total = built.reduce(
    (acc, r) => {
      const b = breakdown(sub, r.stops);
      return { travel: acc.travel + b.travel, local: acc.local + b.local, service: acc.service + b.service };
    },
    { travel: 0, local: 0, service: 0 },
  );

  return {
    routes: built,
    totalTime: total.travel + total.local + total.service,
    travel: total.travel,
    local: total.local,
    service: total.service,
    log,
    unrouted,
  };
}
