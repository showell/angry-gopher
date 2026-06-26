// solver.ts — the routing brain. Given the day's orders (which houses ordered,
// grouped by neighborhood) and the travel substrate, it assigns neighborhoods to
// trucks and orders each truck's stops to minimize TOTAL driver time. Pure: no
// DOM. The map just draws what this returns.
//
// A truck's time has three parts, all of which the solver now feels:
//
//   1. TRAVEL — artery time between stops (the substrate's shortest paths), fast.
//   2. LOCAL  — time driving each neighborhood's SLOW ring road to reach its
//      ordered houses, entering at the gate facing where it came from and leaving
//      at the gate facing where it's headed (see geography.ringWalk). A
//      neighborhood merely *threaded* on the way through still costs the short
//      arc between its two gates — but only the delivery visit drives the full
//      ring; a re-thread pays transit only.
//   3. SERVICE — a small per-order beat at each door.
//
// LOCAL depends on the entry/exit gates, so it depends on the route's *shape* —
// which means reordering a route, or which truck takes a neighborhood, changes
// the cost. There's no flat per-visit charge; the slow ring geometry itself does
// the consolidation-deterrence (two trucks each pay their own ring driving).
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

export type Move = { kind: "merge" | "2-opt" | "or-opt" | "balance"; saved: number; detail: string };

export type Plan = {
  routes: Route[];
  totalTime: number;
  travel: number; // total artery time across the fleet
  local: number; // total in-neighborhood (slow ring) driving
  service: number; // total per-order time (a constant for a given day)
  spread: number; // longest route time − shortest, a measure of (im)balance
  log: Move[];
  unrouted: Stop[]; // demand that didn't fit the fleet (should be empty; surfaced if not)
};

const CAP = FLEET.totesPerTruck;

// Balance levels for the B-knob: minutes of total time we'll spend per minute of
// route-time stdev cut. 0 = pure total-time (but the free tie-break still runs).
export const BALANCE_LEVELS = [0, 3, 6, 12];
export const BALANCE_LABELS = ["off", "low", "med", "high"];

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

  // A neighborhood drives its full delivery ring ONCE (at its first occurrence);
  // if the shortest path threads back through it later, that pass costs only the
  // short gate-to-gate transit arc — you don't re-loop a town you already did.
  const delivered = new Set<string>();
  let local = 0;
  for (let i = 1; i < nodes.length - 1; i++) {
    const node = nodes[i];
    if (node === "FC") continue;
    const full = houses.get(node);
    const visit = full && full.length && !delivered.has(node) ? full : [];
    if (visit.length) delivered.add(node);
    const entry = gateAngle(node, nodeAt(nodes[i - 1]));
    const exit = gateAngle(node, nodeAt(nodes[i + 1]));
    local += localMinutes(node, entry, exit, houseAngles(node, visit));
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

/** Population stdev of a set of route times — our (im)balance measure. */
function stdev(times: number[]): number {
  if (times.length === 0) return 0;
  const mean = times.reduce((a, b) => a + b, 0) / times.length;
  return Math.sqrt(times.reduce((a, t) => a + (t - mean) ** 2, 0) / times.length);
}

/**
 * Even out the fleet by relocating single stops. A FREE move is one that leaves
 * total time unchanged (within a minute) but shrinks the route-time spread — the
 * "give the tied neighborhood to the lighter truck" move, at no cost; it always
 * runs. When `lambda` > 0 we also make PAID moves, spending up to `lambda` min of
 * total time per minute of stdev cut, to compress genuinely lopsided routes.
 */
function rebalance(sub: Substrate, routes: Stop[][], lambda: number, log: Move[]): void {
  const TIE = 0.75; // minutes treated as "no change in total time"
  for (let guard = 0; guard < 400; guard++) {
    const times = routes.map((r) => costOf(sub, r));
    const spread0 = stdev(times.filter((_, i) => routes[i].length > 0));

    type Cand = { r: number; s: number; t: number; pos: number; dTotal: number; dSpread: number; free: boolean };
    let pick: Cand | null = null;
    const score = (c: Cand): number => (c.free ? c.dSpread : c.dTotal + lambda * c.dSpread);

    for (let r = 0; r < routes.length; r++) {
      for (let s = 0; s < routes[r].length; s++) {
        const stop = routes[r][s];
        const without = [...routes[r].slice(0, s), ...routes[r].slice(s + 1)];
        const newRcost = costOf(sub, without);
        for (let t = 0; t < routes.length; t++) {
          if (t === r) continue;
          if (loadOf(routes[t]) + stop.orders > CAP) continue;
          for (let pos = 0; pos <= routes[t].length; pos++) {
            const newTcost = costOf(sub, [...routes[t].slice(0, pos), stop, ...routes[t].slice(pos)]);
            const dTotal = newRcost - times[r] + (newTcost - times[t]);
            const nt = times.slice();
            nt[r] = newRcost;
            nt[t] = newTcost;
            const after = nt.filter((_, i) => (i === r ? without.length > 0 : true) && routes[i].length > 0);
            const dSpread = stdev(after) - spread0;
            const free = Math.abs(dTotal) <= TIE && dSpread < -1e-6;
            const paid = lambda > 0 && dTotal > TIE && dTotal + lambda * dSpread < -1e-6;
            if (!free && !paid) continue;
            const cand: Cand = { r, s, t, pos, dTotal, dSpread, free };
            const wins = !pick ? true : cand.free !== pick.free ? cand.free : score(cand) < score(pick);
            if (wins) pick = cand;
          }
        }
      }
    }

    if (!pick) break;
    const stop = routes[pick.r][pick.s];
    routes[pick.r] = [...routes[pick.r].slice(0, pick.s), ...routes[pick.r].slice(pick.s + 1)];
    routes[pick.t] = [...routes[pick.t].slice(0, pick.pos), stop, ...routes[pick.t].slice(pick.pos)];
    log.push({ kind: "balance", saved: -pick.dTotal, detail: `${pick.free ? "tie-break" : "balance"}: ${stop.nbhd} → another truck` });
    routes.splice(0, routes.length, ...routes.filter((r) => r.length > 0));
  }
}

/** Contiguous arc-subsets (size 1..3) of a neighborhood's houses, by ring angle. */
function arcSubsets(name: string, houses: number[]): number[][] {
  if (houses.length < 2) return [];
  const ang = houseAngles(name, houses);
  const order = houses.map((h, i) => ({ h, a: ang[i] })).sort((x, y) => x.a - y.a).map((p) => p.h);
  const out: number[][] = [];
  const seen = new Set<string>();
  const maxK = Math.min(2, houses.length - 1);
  for (let k = 1; k <= maxK; k++) {
    for (let start = 0; start < order.length; start++) {
      const S: number[] = [];
      for (let j = 0; j < k; j++) S.push(order[(start + j) % order.length]);
      const key = [...S].sort((a, b) => a - b).join(",");
      if (!seen.has(key)) {
        seen.add(key);
        out.push(S);
      }
    }
  }
  return out;
}

/**
 * Voluntary split delivery: hand a contiguous arc of one neighborhood's houses
 * to a SECOND truck when it improves the penalized objective (total + lambda·
 * stdev). Never forced — splitting adds a second truck's ring driving, so it
 * only happens when capacity relief or balance more than pays for it.
 */
function splitPass(sub: Substrate, routes: Stop[][], lambda: number, log: Move[]): void {
  for (let guard = 0; guard < 60; guard++) {
    const times = routes.map((r) => costOf(sub, r));
    const spread0 = stdev(times.filter((_, i) => routes[i].length > 0));

    type Cand = { a: number; sa: number; b: number; pos: number; S: number[]; rest: number[]; g: number };
    let pick: Cand | null = null;

    for (let a = 0; a < routes.length; a++) {
      for (let sa = 0; sa < routes[a].length; sa++) {
        const N = routes[a][sa].nbhd;
        const H = routes[a][sa].houses;
        if (H.length < 2) continue;
        const subsets = arcSubsets(N, H);
        for (let b = 0; b < routes.length; b++) {
          if (b === a || routes[b].some((s) => s.nbhd === N)) continue;
          for (const S of subsets) {
            if (loadOf(routes[b]) + S.length > CAP) continue;
            const rest = H.filter((h) => !S.includes(h));
            const newA = routes[a].map((s, i) => (i === sa ? { nbhd: N, orders: rest.length, houses: rest } : s));
            const costA = costOf(sub, newA);
            const Sstop: Stop = { nbhd: N, orders: S.length, houses: S };
            let bestB = Infinity;
            let bestPos = 0;
            for (let pos = 0; pos <= routes[b].length; pos++) {
              const c = costOf(sub, [...routes[b].slice(0, pos), Sstop, ...routes[b].slice(pos)]);
              if (c < bestB) {
                bestB = c;
                bestPos = pos;
              }
            }
            const dTotal = costA - times[a] + (bestB - times[b]);
            const nt = times.slice();
            nt[a] = costA;
            nt[b] = bestB;
            const dSpread = stdev(nt.filter((_, i) => routes[i].length > 0)) - spread0;
            const g = dTotal + lambda * dSpread;
            if (g < -1e-6 && (!pick || g < pick.g)) pick = { a, sa, b, pos: bestPos, S, rest, g };
          }
        }
      }
    }

    if (!pick) break;
    const N = routes[pick.a][pick.sa].nbhd;
    routes[pick.a] = routes[pick.a].map((s, i) => (i === pick!.sa ? { nbhd: N, orders: pick!.rest.length, houses: pick!.rest } : s));
    const Sstop: Stop = { nbhd: N, orders: pick.S.length, houses: pick.S };
    routes[pick.b] = [...routes[pick.b].slice(0, pick.pos), Sstop, ...routes[pick.b].slice(pick.pos)];
    log.push({ kind: "balance", saved: -pick.g, detail: `split ${N}: ${pick.S.length} of ${pick.S.length + pick.rest.length} totes to another truck` });
  }
}

/**
 * Merge any stops that hit the same neighborhood into one. A relocation pass
 * (or-opt / rebalance) can move a stop onto a truck that already serves that
 * neighborhood, leaving the route visiting it twice; normalize to one stop per
 * neighborhood (keeping the first occurrence's slot — twoOpt re-tidies after).
 */
function coalesceStops(route: Stop[]): Stop[] {
  const byNbhd = new Map<string, Stop>();
  const out: Stop[] = [];
  for (const s of route) {
    const existing = byNbhd.get(s.nbhd);
    if (existing) {
      existing.houses = existing.houses.concat(s.houses);
      existing.orders = existing.houses.length;
    } else {
      const copy: Stop = { nbhd: s.nbhd, orders: s.houses.length, houses: [...s.houses] };
      byNbhd.set(s.nbhd, copy);
      out.push(copy);
    }
  }
  return out;
}

/** Plan the fleet for a day's orders. Deterministic — same orders + lambda, same plan. */
export function solve(sub: Substrate, orders: Map<string, number[]>, lambda = 0, allowSplit = true): Plan {
  const log: Move[] = [];
  const routes: Stop[][] = customers(orders).map((c) => [c]);

  construct(sub, routes, log, false); // savings merges while they help
  if (routes.length > FLEET.trucks) construct(sub, routes, log, true); // squeeze into the fleet

  for (const r of routes) twoOpt(sub, r, log);
  orOpt(sub, routes, log);
  for (const r of routes) twoOpt(sub, r, log); // re-tidy after relocations

  rebalance(sub, routes, lambda, log); // free tie-breaks always; paid balancing when lambda > 0
  if (allowSplit) {
    splitPass(sub, routes, lambda, log); // voluntary split delivery, if it pays
    rebalance(sub, routes, lambda, log); // re-settle with any split in place
  }
  for (let i = 0; i < routes.length; i++) routes[i] = coalesceStops(routes[i]); // one stop per neighborhood
  for (const r of routes) twoOpt(sub, r, log); // tidy any route the passes reshaped

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

  const ts = built.map((r) => r.time);
  const spread = ts.length ? Math.max(...ts) - Math.min(...ts) : 0;

  return {
    routes: built,
    totalTime: total.travel + total.local + total.service,
    travel: total.travel,
    local: total.local,
    service: total.service,
    spread,
    log,
    unrouted,
  };
}
