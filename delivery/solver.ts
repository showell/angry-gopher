// solver.ts — the routing brain. Given the day's demand (orders per
// neighborhood) and the travel substrate, it assigns neighborhoods to trucks
// and orders each truck's stops to minimize TOTAL driver time (the sum across
// trucks). Pure: no DOM, no canvas. The map just draws what this returns.
//
// THE KEY SIMPLIFICATION that makes this tractable and explainable:
//
//   total time = RING·(#stops) + SERVICE·(#orders) + Σ travel
//
//   - SERVICE·(#orders) is fixed: every order is delivered exactly once.
//   - RING·(#stops) is fixed too — a "stop" is one (truck, neighborhood) visit,
//     and the *number* of stops is decided up front when we build customers:
//     one per neighborhood, plus an extra only when a neighborhood's demand
//     exceeds a truck (a forced split, which honestly pays a second RING). We
//     NEVER split a neighborhood voluntarily — that's RING doing its job, but
//     it does it at construction time, not during routing.
//
//   So once customers exist, RING and SERVICE are an additive constant, and
//   every routing decision — which truck, what order — only moves TRAVEL. The
//   solver is therefore a plain minimize-total-travel CVRP. That's why "idle a
//   truck" works purely through travel: folding two routes into one drops a
//   pair of FC round-trip legs.
//
// Construction is Clarke–Wright savings (greedy best-merge); improvement is
// 2-opt within a route and Or-opt across routes. Every accepted move records a
// "saved N min" reason, for the manager-override phase to surface later.

import { FLEET } from "./geography.ts";
import { RING, SERVICE } from "./roadgraph.ts";
import type { Substrate } from "./roadgraph.ts";

export type Stop = { nbhd: string; orders: number };

export type Route = {
  stops: Stop[]; // ordered neighborhoods this truck visits (FC is implicit at both ends)
  orders: number; // totes carried (<= capacity)
  travel: number; // pure drive time, FC -> stops -> FC
  time: number; // travel + RING·stops + SERVICE·orders (this truck's slice of the total)
};

export type Move = { kind: "merge" | "2-opt" | "or-opt"; saved: number; detail: string };

export type Plan = {
  routes: Route[]; // one per truck actually used (empty trucks are simply absent)
  totalTime: number; // RING + SERVICE floor + all travel
  travel: number; // total drive time across the fleet
  floor: number; // RING·stops + SERVICE·orders (the fixed part)
  log: Move[]; // the moves that built this plan, best-saving first-ish
  unrouted: Stop[]; // demand that didn't fit the fleet (should be empty; surfaced if not)
};

const CAP = FLEET.totesPerTruck;

/** Orders carried on a route. */
function loadOf(stops: Stop[]): number {
  return stops.reduce((s, c) => s + c.orders, 0);
}

/** Pure drive time of a stop sequence: FC -> s0 -> ... -> sk -> FC. */
function travelOf(sub: Substrate, stops: Stop[]): number {
  if (stops.length === 0) return 0;
  let t = sub.time("FC", stops[0].nbhd);
  for (let i = 1; i < stops.length; i++) t += sub.time(stops[i - 1].nbhd, stops[i].nbhd);
  return t + sub.time(stops[stops.length - 1].nbhd, "FC");
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
    const t = travelOf(sub, o);
    if (t < bestT) {
      bestT = t;
      best = o;
    }
  }
  return best;
}

/** Demand map -> customers. One per neighborhood; a forced split when demand > capacity. */
function customers(demand: Map<string, number>): Stop[] {
  const out: Stop[] = [];
  for (const [nbhd, d] of demand) {
    let left = d;
    while (left > CAP) {
      out.push({ nbhd, orders: CAP });
      left -= CAP;
    }
    if (left > 0) out.push({ nbhd, orders: left });
  }
  return out;
}

/** Greedy Clarke–Wright: repeatedly merge the two routes that save the most travel. */
function construct(sub: Substrate, routes: Stop[][], log: Move[], force: boolean): void {
  for (;;) {
    let best: { i: number; j: number; merged: Stop[]; saved: number } | null = null;
    for (let i = 0; i < routes.length; i++) {
      for (let j = i + 1; j < routes.length; j++) {
        if (loadOf(routes[i]) + loadOf(routes[j]) > CAP) continue;
        const merged = bestJoin(sub, routes[i], routes[j]);
        const saved = travelOf(sub, routes[i]) + travelOf(sub, routes[j]) - travelOf(sub, merged);
        if (!best || saved > best.saved) best = { i, j, merged, saved };
      }
    }
    if (!best) break; // nothing fits — capacity-stuck
    if (!force && best.saved <= 1e-9) break; // no further travel win
    if (force && routes.length <= FLEET.trucks) break; // fleet now fits
    log.push({
      kind: "merge",
      saved: best.saved,
      detail: `${best.merged.map((s) => s.nbhd).join(" · ")}`,
    });
    routes[best.i] = best.merged;
    routes.splice(best.j, 1);
  }
}

/** 2-opt: reverse a sub-segment of one route while it keeps cutting travel. */
function twoOpt(sub: Substrate, stops: Stop[], log: Move[]): void {
  let improved = true;
  while (improved) {
    improved = false;
    for (let i = 0; i < stops.length - 1; i++) {
      for (let k = i + 1; k < stops.length; k++) {
        const before = travelOf(sub, stops);
        const candidate = [...stops.slice(0, i), ...stops.slice(i, k + 1).reverse(), ...stops.slice(k + 1)];
        const saved = before - travelOf(sub, candidate);
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
        const baseR = travelOf(sub, routes[r]);
        const newR = travelOf(sub, without);

        let best: { t: number; pos: number; gain: number } | null = null;
        for (let t = 0; t < routes.length; t++) {
          if (t === r) continue;
          if (loadOf(routes[t]) + stop.orders > CAP) continue;
          const baseT = travelOf(sub, routes[t]);
          for (let pos = 0; pos <= routes[t].length; pos++) {
            const into = [...routes[t].slice(0, pos), stop, ...routes[t].slice(pos)];
            const gain = baseR - newR + (baseT - travelOf(sub, into));
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

/** Plan the fleet for a day's demand. Deterministic — same demand, same plan. */
export function solve(sub: Substrate, demand: Map<string, number>): Plan {
  const log: Move[] = [];
  const cust = customers(demand);
  const routes: Stop[][] = cust.map((c) => [c]);

  construct(sub, routes, log, false); // savings merges while they help travel
  if (routes.length > FLEET.trucks) construct(sub, routes, log, true); // squeeze into the fleet

  for (const r of routes) twoOpt(sub, r, log);
  orOpt(sub, routes, log);
  for (const r of routes) twoOpt(sub, r, log); // re-tidy after relocations

  // Anything still over the fleet count couldn't be merged (capacity-stuck): be honest.
  const unrouted: Stop[] = [];
  while (routes.length > FLEET.trucks) unrouted.push(...routes.pop()!);

  const built: Route[] = routes
    .filter((r) => r.length > 0)
    .map((stops) => {
      const travel = travelOf(sub, stops);
      const orders = loadOf(stops);
      return { stops, orders, travel, time: travel + RING * stops.length + SERVICE * orders };
    })
    .sort((a, b) => b.orders - a.orders);

  const stopCount = built.reduce((s, r) => s + r.stops.length, 0) + unrouted.length;
  const orderCount = built.reduce((s, r) => s + r.orders, 0) + loadOf(unrouted);
  const floor = RING * stopCount + SERVICE * orderCount;
  const travel = built.reduce((s, r) => s + r.travel, 0);

  return { routes: built, totalTime: floor + travel, travel, floor, log, unrouted };
}
