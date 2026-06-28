// solver.ts — the routing brain. Given the day's orders (which houses ordered,
// grouped by neighborhood) and the travel substrate, it assigns neighborhoods to
// trucks and orders each truck's stops to minimize a blend of driver time and
// tote-carrying cost — so a customer near the FC isn't served last because their
// goods rode a far truck's whole loop. Pure: no DOM. The map draws what we return.
//
// The PHYSICAL day a truck drives has three parts:
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
// Those three are the real minutes (route.time, the playback clock) — breakdown()
// computes them for DISPLAY only. The SOLVER never reads them. It optimizes a
// separate INTEGER cost, PAIN (painOf): each segment's integer driving time weighted
// by the load it carries — EMPTY_PAIN + TOTE_PAIN·(totes still aboard) — so a fuller,
// later-served customer hurts more (drop weight early / serve close customers soon).
// The ring is a flat RING_UNIT per delivered neighborhood: no trig, no shape
// dependence. That keeps painOf transcendental-free (cos/sin/hypot differ by ULPs
// across JS engines — integer math is bit-identical everywhere) AND fast — no
// geometry in the hot path. Two trucks splitting a neighborhood still each pay the
// flat ring charge, so the consolidation deterrence survives.
//
// Construction is Clarke–Wright savings (greedy best-merge); improvement is
// 2-opt within a route and Or-opt across routes. Every accepted move records a
// "saved N pain" reason, for the manager-override phase to surface later.

import { FLEET, TRUCK_ANCHORS, TRUCK_CAPS, MAX_CAP, DEFER_LAST, gateAngle, houseAngles, nodeAt, arcGroups } from "./geography.ts";
import { SERVICE, localMinutes } from "./roadgraph.ts";
import type { Substrate } from "./roadgraph.ts";

// A stop's `pin` (when set) is the truck slot it's frozen to: the seed houses of
// an anchor neighborhood that lock that truck's regional identity. Pinned stops
// never relocate, and two pinned stops never share a truck — that's the whole
// machinery behind "Truck 1 is always the West Seattle truck".
export type Stop = { nbhd: string; orders: number; houses: number[]; pin?: number }; // ordered house indices

// How many of an anchor neighborhood's houses to freeze to its slot. Capped low
// so the truck keeps room to gather its region (and the rest can still divert if
// the math ever wants it); in practice anchors rarely exceed this, so the whole
// neighborhood usually rides its own truck anyway.
const ANCHOR_PIN = 2;

/** Anchor neighborhood name -> its truck slot (index into the fleet). */
const ANCHOR_SLOT = new Map(TRUCK_ANCHORS.map((name, slot) => [name, slot]));

/** FC-adjacent neighborhoods held out of construction and placed into slack last. */
const DEFER_SET = new Set(DEFER_LAST);

/** Does this route carry an anchor's frozen seed (so it owns a fixed truck slot)? */
function hasAnchor(route: Stop[]): boolean {
  return route.some((s) => s.pin !== undefined);
}

export type Route = {
  stops: Stop[]; // ordered neighborhoods this truck visits (FC is implicit at both ends)
  orders: number; // totes carried (<= capacity)
  travel: number; // artery time between stops
  time: number; // travel + local + service (this truck's slice of the total)
};

export type Move = {
  kind: "merge" | "2-opt" | "or-opt" | "swap" | "balance" | "corridor";
  saved: number;
  detail: string;
  // A snapshot of the whole assignment right after this move landed — present on
  // every move that remakes a home→truck pair (so the `A` animation can replay
  // the solve frame by frame). Absent on 2-opt, which only reorders one route.
  frame?: Stop[][];
  // The houses this move actually moved/assigned (`nbhd#h` keys) — the animation
  // pops these so the eye lands on where the action just happened.
  touched?: string[];
};

/** One step of the solve, ready to draw: who serves whom, what just moved, a caption. */
export type SolveFrame = { routes: { stops: Stop[] }[]; touched: string[]; label: string };

/** A deep-enough copy of the live routes to survive later mutation. */
function snapshot(routes: Stop[][]): Stop[][] {
  return routes.map((r) => r.map((s) => ({ ...s, houses: [...s.houses] })));
}

/** House keys (`nbhd#h`) for a set of stops — the homes a move touched. */
function keysOf(stops: { nbhd: string; houses: number[] }[]): string[] {
  return stops.flatMap((s) => s.houses.map((h) => `${s.nbhd}#${h}`));
}

/** House keys for one neighborhood's houses. */
function keys(nbhd: string, houses: number[]): string[] {
  return houses.map((h) => `${nbhd}#${h}`);
}

export type Plan = {
  routes: Route[];
  totalTime: number;
  travel: number; // total artery time across the fleet
  local: number; // total in-neighborhood (slow ring) driving
  service: number; // total per-order time (a constant for a given day)
  spread: number; // longest route time − shortest, a measure of (im)balance
  log: Move[];
  frames: SolveFrame[]; // the solve replayed step by step (for the `A` animation)
  unrouted: Stop[]; // demand that didn't fit the fleet (should be empty; surfaced if not)
};

// A chunk size for splitting a too-big neighborhood into stops — the largest a
// single truck could ever hold. (No neighborhood exceeds this anyway, so it's a
// safety bound, not a routine split.)
const CAP = MAX_CAP;

function loadOf(stops: Stop[]): number {
  return stops.reduce((s, c) => s + c.orders, 0);
}

// Tote capacity available to a route: its anchor's slot cap (west 14 / east 12),
// else the max — a free cluster could still land in any idle slot, and its real
// slot cap is enforced at final assignment. Almost every route is anchored.
function capOf(route: Stop[]): number {
  const anc = route.find((s) => s.pin !== undefined);
  return anc ? TRUCK_CAPS[anc.pin!] : MAX_CAP;
}

/** Houses ordered at each neighborhood for one route (so the cost knows the ring arc). */
function housesByNbhd(stops: Stop[]): Map<string, number[]> {
  const m = new Map<string, number[]>();
  for (const s of stops) m.set(s.nbhd, (m.get(s.nbhd) ?? []).concat(s.houses));
  return m;
}

/** The neighborhoods a route actually drives through, FC → stops → FC, with the
 *  shortest path between each pair expanded (so threaded-through towns appear). */
function pathNodes(sub: Substrate, stops: Stop[]): string[] {
  const waypoints = ["FC", ...stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    for (const node of sub.path(waypoints[i - 1], waypoints[i])) {
      if (nodes[nodes.length - 1] !== node) nodes.push(node);
    }
  }
  return nodes;
}

type Breakdown = { travel: number; local: number; service: number; time: number };

/**
 * DISPLAY breakdown of a stop sequence — the real minutes for the playback clock.
 * Expands the shortest path so every neighborhood the truck drives through
 * (delivered-to OR threaded) is priced with the correct entry/exit gates. `travel`
 * is integer (rounded artery edges); `local` is the float ring-arc geometry, used
 * ONLY here for the animation — never for a solver decision. The solver uses painOf.
 */
function breakdown(sub: Substrate, stops: Stop[]): Breakdown {
  if (stops.length === 0) return { travel: 0, local: 0, service: 0, time: 0 };

  const nodes = pathNodes(sub, stops);
  const houses = housesByNbhd(stops);
  // A neighborhood drives its full delivery ring ONCE (at its first occurrence);
  // if the shortest path threads back through it later, that pass costs only the
  // short gate-to-gate transit arc — you don't re-loop a town you already did.
  const delivered = new Set<string>();
  let travel = 0;
  let local = 0;
  for (let i = 1; i < nodes.length; i++) {
    travel += sub.time(nodes[i - 1], nodes[i]);
    const node = nodes[i];
    if (node === "FC" || i >= nodes.length - 1) continue;
    const full = houses.get(node);
    const visit = full && full.length && !delivered.has(node) ? full : [];
    const entry = gateAngle(node, nodeAt(nodes[i - 1]));
    const exit = gateAngle(node, nodeAt(nodes[i + 1]));
    local += localMinutes(node, entry, exit, houseAngles(node, visit));
    if (visit.length) delivered.add(node);
  }

  const service = loadOf(stops) * SERVICE;
  return { travel, local, service, time: travel + local + service };
}

// The PAIN model — the solver's integer cost. A segment's driving time (integer)
// weighted by the load it carries: an empty leg costs EMPTY_PAIN per minute, each
// tote still aboard adds TOTE_PAIN more. So an empty truck is ×10 and a fully-loaded
// west truck (14 totes) is ×38 — a strong bias toward dropping weight early. The
// ring is a flat RING_UNIT per delivered neighborhood (no trig, no shape dependence).
const EMPTY_PAIN = 10;
const TOTE_PAIN = 2;
const RING_UNIT = 1;

/**
 * Integer pain of a stop sequence — the ONLY cost the solver's greedy moves compare.
 * Pure integer arithmetic (rounded artery times × integer load multiplier + flat
 * ring), so it is bit-identical across JS engines and free of the cos/sin/hypot that
 * made earlier float costs diverge between node and the browser. No geometry in this
 * hot path: that's both the determinism win and the speed win.
 */
export function painOf(sub: Substrate, stops: Stop[]): number {
  if (stops.length === 0) return 0;

  const nodes = pathNodes(sub, stops);
  const houses = housesByNbhd(stops);
  const delivered = new Set<string>();
  let pain = 0;
  let aboard = loadOf(stops); // totes still on the truck (all of them, leaving the FC)
  for (let i = 1; i < nodes.length; i++) {
    pain += sub.time(nodes[i - 1], nodes[i]) * (EMPTY_PAIN + TOTE_PAIN * aboard);
    const node = nodes[i];
    if (node === "FC" || i >= nodes.length - 1) continue;
    const full = houses.get(node);
    if (full && full.length && !delivered.has(node)) {
      pain += RING_UNIT * (EMPTY_PAIN + TOTE_PAIN * aboard); // flat ring, charged at arrival load
      delivered.add(node);
      aboard -= full.length; // dropped here, so lighter from now on
    }
  }
  return pain;
}

const costOf = (sub: Substrate, stops: Stop[]): number => painOf(sub, stops);

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

/**
 * Orders map -> customers. One stop per neighborhood (a forced split when demand
 * > capacity). An anchor neighborhood is split into its frozen seed — the first
 * ANCHOR_PIN houses, pinned to the anchor's truck slot — and the overflow, a
 * normal free stop that flows by cost (and usually coalesces right back onto the
 * same truck). The seed is what guarantees the slot's regional identity.
 */
function customers(orders: Map<string, number[]>, arcSplit: boolean): Stop[] {
  const out: Stop[] = [];
  // Free (non-pinned) homes become clusters. arcSplit decomposes them by ring ARC —
  // the natural sub-units a passing truck can each grab cheaply (the S487 fix) —
  // instead of one monolithic lot auctioned by capacity. Either way, same-neighborhood
  // clusters re-merge in construction when route savings don't beat the extra ring.
  const free = (nbhd: string, idx: number[]): void => {
    const groups = arcSplit ? arcGroups(nbhd, idx) : chunk(idx, CAP);
    for (const houses of groups) if (houses.length) out.push({ nbhd, orders: houses.length, houses });
  };
  for (const [nbhd, idx] of orders) {
    const slot = ANCHOR_SLOT.get(nbhd);
    if (slot === undefined) {
      free(nbhd, idx);
      continue;
    }
    const seed = idx.slice(0, ANCHOR_PIN);
    out.push({ nbhd, orders: seed.length, houses: seed, pin: slot });
    free(nbhd, idx.slice(ANCHOR_PIN));
  }
  return out;
}

/** Split a house list into chunks no larger than `size` (the no-arc-split default). */
function chunk(idx: number[], size: number): number[][] {
  const out: number[][] = [];
  for (let i = 0; i < idx.length; i += size) out.push(idx.slice(i, i + size));
  return out;
}

/** Greedy Clarke–Wright: repeatedly merge the two routes that save the most total time. */
function construct(sub: Substrate, routes: Stop[][], log: Move[], force: boolean): void {
  for (;;) {
    let best: { i: number; j: number; merged: Stop[]; saved: number } | null = null;
    for (let i = 0; i < routes.length; i++) {
      for (let j = i + 1; j < routes.length; j++) {
        const cap = hasAnchor(routes[i]) ? capOf(routes[i]) : capOf(routes[j]); // merged cap = its anchor's
        if (loadOf(routes[i]) + loadOf(routes[j]) > cap) continue;
        if (hasAnchor(routes[i]) && hasAnchor(routes[j])) continue; // anchors keep their own trucks
        const merged = bestJoin(sub, routes[i], routes[j]);
        const saved = costOf(sub, routes[i]) + costOf(sub, routes[j]) - costOf(sub, merged);
        if (!best || saved > best.saved) best = { i, j, merged, saved };
      }
    }
    if (!best) break; // nothing fits — capacity-stuck
    if (!force && best.saved <= 1e-9) break; // no further win
    if (force && routes.length <= FLEET.trucks) break; // fleet now fits
    log.push({ kind: "merge", saved: best.saved, detail: `${best.merged.map((s) => s.nbhd).join(" · ")}`, frame: snapshot(routes), touched: keysOf(best.merged) });
    routes[best.i] = best.merged;
    routes.splice(best.j, 1);
  }
}

/**
 * Last-resort packing when whole-route merges can't squeeze into the fleet. The
 * no-anchor-merge rule keeps 8 anchor routes apart, which can fragment capacity:
 * total demand fits under total capacity, but no single truck has room for a
 * whole leftover cluster. So we keep every anchor route (plus the biggest few
 * non-anchor clusters, up to the fleet size) and redistribute the rest house by
 * house into trucks with room — splitting a neighborhood if we must. Total demand
 * sits under total capacity, so with splittable houses this always lands; the
 * later cost passes then relocate what they can to cheaper trucks.
 */
function forcePlace(sub: Substrate, routes: Stop[][], log: Move[], costAware: boolean): void {
  const anchored = routes.filter(hasAnchor);
  const clusters = routes.filter((r) => !hasAnchor(r) && r.length > 0).sort((a, b) => loadOf(b) - loadOf(a));
  const keep = Math.max(0, FLEET.trucks - anchored.length);
  const kept = [...anchored, ...clusters.slice(0, keep)];
  const surplus = clusters.slice(keep);

  const appendCost = (route: Stop[], nbhd: string, houses: number[]): number =>
    costOf(sub, [...route, { nbhd, orders: houses.length, houses }]) - costOf(sub, route);

  for (const route of surplus) {
    for (const stop of route) {
      let remaining = stop.houses;
      while (remaining.length) {
        // Prefer the cheapest truck that can take the whole remaining piece —
        // keeps a neighborhood together and on a truck near it.
        let whole: Stop[] | null = null;
        let bestCost = Infinity;
        for (const k of kept) {
          if (capOf(k) - loadOf(k) < remaining.length) continue;
          const c = appendCost(k, stop.nbhd, remaining);
          if (c < bestCost) {
            bestCost = c;
            whole = k;
          }
        }
        if (whole) {
          whole.push({ nbhd: stop.nbhd, orders: remaining.length, houses: remaining });
          log.push({ kind: "or-opt", saved: 0, detail: `capacity placement: ${stop.nbhd} (${remaining.length}) onto a truck with room`, frame: snapshot(routes), touched: keys(stop.nbhd, remaining) });
          break;
        }
        // No single truck fits it whole — place a chunk and loop. Two strategies,
        // raced by solve(): the roomiest (biggest chunk on the most-slack truck —
        // geography-blind) or the cost-aware (cheapest chunk on the cheapest truck —
        // keeps an island like Mercer N off an unrelated NW cluster).
        let into: Stop[] | null = null;
        let takeN = 0;
        if (costAware) {
          let bestc = Infinity;
          for (const k of kept) {
            const free = capOf(k) - loadOf(k);
            if (free <= 0) continue;
            const n = Math.min(free, remaining.length);
            const c = appendCost(k, stop.nbhd, remaining.slice(0, n));
            if (c < bestc) {
              bestc = c;
              into = k;
              takeN = n;
            }
          }
        } else {
          let room = 0;
          for (const k of kept) {
            const free = capOf(k) - loadOf(k);
            if (free > room) {
              room = free;
              into = k;
              takeN = Math.min(free, remaining.length);
            }
          }
        }
        if (!into || takeN <= 0) throw new Error("forcePlace: no truck has room — demand exceeds fleet capacity"); // unreachable: 84 ≤ 96
        const take = remaining.slice(0, takeN);
        remaining = remaining.slice(takeN);
        into.push({ nbhd: stop.nbhd, orders: take.length, houses: take });
        log.push({ kind: "or-opt", saved: 0, detail: `capacity split: ${stop.nbhd} ${take.length} tote(s) onto a truck with room`, frame: snapshot(routes), touched: keys(stop.nbhd, take) });
      }
    }
  }

  routes.splice(0, routes.length, ...kept);
}

/** Insert `stop` into `route` at its cheapest position; return the new route. */
function insertBest(sub: Substrate, route: Stop[], stop: Stop): Stop[] {
  let best = [...route, stop];
  let bestCost = Infinity;
  for (let p = 0; p <= route.length; p++) {
    const cand = [...route.slice(0, p), stop, ...route.slice(p)];
    const c = costOf(sub, cand);
    if (c < bestCost) {
      bestCost = c;
      best = cand;
    }
  }
  return best;
}

/**
 * Place the deferred FC-adjacent neighborhoods (Bellevue, Factoria) into the
 * routes built from everything else. Each goes to the truck whose total time it
 * grows the least (cheapest insertion), splitting across trucks only if no single
 * one has room. Running this AFTER construction is the whole point: the far,
 * hard-to-reach neighborhoods have already claimed their trucks, so these cheap
 * fillers slot into leftover slack instead of crowding a hard neighborhood out.
 */
function placeDeferred(sub: Substrate, routes: Stop[][], deferred: Stop[], log: Move[], costAware: boolean): void {
  for (const stop of [...deferred].sort((a, b) => b.orders - a.orders)) {
    let remaining = stop.houses;
    while (remaining.length) {
      let bestRi = -1;
      let bestRoute: Stop[] | null = null;
      let bestDelta = Infinity;
      for (let ri = 0; ri < routes.length; ri++) {
        if (capOf(routes[ri]) - loadOf(routes[ri]) < remaining.length) continue;
        const cand = insertBest(sub, routes[ri], { nbhd: stop.nbhd, orders: remaining.length, houses: remaining });
        const delta = costOf(sub, cand) - costOf(sub, routes[ri]);
        if (delta < bestDelta) {
          bestDelta = delta;
          bestRi = ri;
          bestRoute = cand;
        }
      }
      if (bestRi >= 0 && bestRoute) {
        routes[bestRi] = bestRoute;
        log.push({ kind: "or-opt", saved: 0, detail: `deferred fill: ${stop.nbhd} (${remaining.length}) into slack`, frame: snapshot(routes), touched: keys(stop.nbhd, remaining) });
        break;
      }
      // No single truck fits it whole — place a chunk and loop (same roomiest vs
      // cost-aware race as forcePlace, switched by the same flag).
      let ri = -1;
      let takeN = 0;
      if (costAware) {
        let bestc = Infinity;
        for (let k = 0; k < routes.length; k++) {
          const free = capOf(routes[k]) - loadOf(routes[k]);
          if (free <= 0) continue;
          const n = Math.min(free, remaining.length);
          const cand = insertBest(sub, routes[k], { nbhd: stop.nbhd, orders: n, houses: remaining.slice(0, n) });
          const delta = costOf(sub, cand) - costOf(sub, routes[k]);
          if (delta < bestc) {
            bestc = delta;
            ri = k;
            takeN = n;
          }
        }
      } else {
        let room = 0;
        for (let k = 0; k < routes.length; k++) {
          const free = capOf(routes[k]) - loadOf(routes[k]);
          if (free > room) {
            room = free;
            ri = k;
            takeN = Math.min(free, remaining.length);
          }
        }
      }
      if (ri < 0 || takeN <= 0) throw new Error("placeDeferred: no truck has room — demand exceeds fleet capacity");
      const take = remaining.slice(0, takeN);
      remaining = remaining.slice(takeN);
      routes[ri] = insertBest(sub, routes[ri], { nbhd: stop.nbhd, orders: take.length, houses: take });
      log.push({ kind: "or-opt", saved: 0, detail: `deferred split: ${stop.nbhd} ${take.length} tote(s) into slack`, frame: snapshot(routes), touched: keys(stop.nbhd, take) });
    }
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
        if (stop.pin !== undefined) continue; // a frozen anchor seed never relocates
        const without = [...routes[r].slice(0, s), ...routes[r].slice(s + 1)];
        const drop = costOf(sub, routes[r]) - costOf(sub, without);

        let best: { t: number; pos: number; gain: number } | null = null;
        for (let t = 0; t < routes.length; t++) {
          if (t === r) continue;
          if (loadOf(routes[t]) + stop.orders > capOf(routes[t])) continue;
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
          log.push({ kind: "or-opt", saved: best.gain, detail: `moved ${stop.nbhd} to another truck`, frame: snapshot(routes), touched: keysOf([stop]) });
          improved = true;
        }
      }
    }
    if (improved) routes.splice(0, routes.length, ...routes.filter((r) => r.length > 0)); // drop emptied trucks
  }
}

/** Remove stop `rm` from a route and reinsert `add` at its cheapest slot. */
function reinsert(sub: Substrate, route: Stop[], rm: number, add: Stop): Stop[] {
  const base = [...route.slice(0, rm), ...route.slice(rm + 1)];
  let best = [...base, add];
  let bestCost = Infinity;
  for (let p = 0; p <= base.length; p++) {
    const cand = [...base.slice(0, p), add, ...base.slice(p)];
    const c = costOf(sub, cand);
    if (c < bestCost) {
      bestCost = c;
      best = cand;
    }
  }
  return best;
}

/**
 * Inter-route exchange: trade one stop between two trucks when it cuts total
 * time. Or-opt only *relocates* a stop, but a near-full truck has no room to
 * receive one — so on a tight fleet (capacity binding) the sole improving move is
 * often a swap, which keeps both loads in budget. Pinned anchor seeds never move,
 * and we never hand a truck a neighborhood it already serves.
 */
function exchange(sub: Substrate, routes: Stop[][], log: Move[]): void {
  for (let guard = 0; guard < 200; guard++) {
    let best: { a: number; b: number; ra: Stop[]; rb: Stop[]; gain: number; sa: Stop; sb: Stop } | null = null;
    for (let a = 0; a < routes.length; a++) {
      for (let b = a + 1; b < routes.length; b++) {
        const base = costOf(sub, routes[a]) + costOf(sub, routes[b]);
        for (let i = 0; i < routes[a].length; i++) {
          const sa = routes[a][i];
          if (sa.pin !== undefined) continue;
          for (let j = 0; j < routes[b].length; j++) {
            const sb = routes[b][j];
            if (sb.pin !== undefined || sa.nbhd === sb.nbhd) continue;
            if (loadOf(routes[a]) - sa.orders + sb.orders > capOf(routes[a])) continue;
            if (loadOf(routes[b]) - sb.orders + sa.orders > capOf(routes[b])) continue;
            // A swap onto a truck that already serves the neighborhood is allowed:
            // coalesce the duplicate before costing, so CONSOLIDATING a split
            // neighborhood onto one truck (the natural corridor fix a human eye
            // spots instantly) is valued for real instead of forbidden outright.
            const ra = coalesceStops(reinsert(sub, routes[a], i, sb));
            const rb = coalesceStops(reinsert(sub, routes[b], j, sa));
            const gain = base - (costOf(sub, ra) + costOf(sub, rb));
            if (gain > 1e-6 && (!best || gain > best.gain)) best = { a, b, ra, rb, gain, sa, sb };
          }
        }
      }
    }
    if (!best) break;
    routes[best.a] = best.ra;
    routes[best.b] = best.rb;
    log.push({ kind: "swap", saved: best.gain, detail: `traded a stop between two trucks`, frame: snapshot(routes), touched: keysOf([best.sa, best.sb]) });
  }
}

/** Insert `add` into `route` at the cheapest position, coalescing if the route
 *  already touches that neighborhood (e.g. it was threading it). */
function cheapestInsert(sub: Substrate, route: Stop[], add: Stop): Stop[] {
  let best = coalesceStops([...route, add]);
  let bestCost = costOf(sub, best);
  for (let p = 0; p < route.length; p++) {
    const cand = coalesceStops([...route.slice(0, p), add, ...route.slice(p)]);
    const c = costOf(sub, cand);
    if (c < bestCost) {
      bestCost = c;
      best = cand;
    }
  }
  return best;
}

/**
 * Corridor repair — the final consolidation. After every reshaping pass, a truck can
 * be left driving THROUGH a neighborhood (threading its gates on a shortest path)
 * whose totes ride on a DIFFERENT truck that makes a special trip there. That's the
 * "skip the middle" a dispatcher spots at a glance — on a chain A–B–C with no A–C
 * shortcut, holding A and C means you pass B for free, so you may as well deliver it.
 * ("I drive past Factoria every day — why am I being sent to Redmond?") Move the
 * threaded middle onto the truck already passing through: directly if it has room,
 * else by trading one of its stops to the truck that held the middle — whenever total
 * pain drops. Only threaded nodes are candidates, so it stays cheap; it runs LAST,
 * because the earlier passes (rebalance/split/coalesce) are what create these.
 */
/** Cost of a route as the pipeline will LEAVE it — after the twoOpt re-tidy that runs
 *  once corridorRepair finishes. Candidate moves are built with cheapestInsert, which
 *  inserts without reordering the existing stops; an honest gain has to score the
 *  tidied order it'll actually settle into, or it rejects moves that only pay off post-
 *  tidy (the S14 7/1 split looked like −10 raw but is +18 once T1 reorders). */
function tidiedCost(sub: Substrate, stops: Stop[]): number {
  const copy = stops.map((s) => ({ ...s, houses: [...s.houses] }));
  twoOpt(sub, copy, []);
  return costOf(sub, copy);
}

// `shackle` keeps split-swaps capacity-neutral (carve exactly the traded stop's size) —
// the conservative half of the corridor race. Unshackled, the slice runs as heavy as
// capacity allows (the S14 fix). solve() runs both and keeps the cheaper.
function corridorRepair(sub: Substrate, routes: Stop[][], log: Move[], cap: (i: number) => number, shackle = false): void {
  for (let guard = 0; guard < 50; guard++) {
    let best:
      | { t: number; tp: number; nt: Stop[]; ntp: Stop[]; gain: number; B: string; via: string; touched: string[] }
      | null = null;
    for (let t = 0; t < routes.length; t++) {
      if (routes[t].length === 0) continue;
      const delivered = new Set(routes[t].map((s) => s.nbhd));
      const threaded = new Set(pathNodes(sub, routes[t]).filter((n) => n !== "FC" && !delivered.has(n)));
      for (const B of threaded) {
        const tp = routes.findIndex((r) => r.some((s) => s.nbhd === B));
        if (tp < 0 || tp === t) continue;
        const Bstop = routes[tp].find((s) => s.nbhd === B)!;
        if (Bstop.pin !== undefined) continue; // a frozen anchor seed stays put
        const base = tidiedCost(sub, routes[t]) + tidiedCost(sub, routes[tp]);
        const without = routes[tp].filter((s) => s.nbhd !== B);
        // (a) the pass-through truck just absorbs the middle, if it has room
        if (loadOf(routes[t]) + Bstop.orders <= cap(t)) {
          const nt = cheapestInsert(sub, routes[t], Bstop);
          const gain = base - (tidiedCost(sub, nt) + tidiedCost(sub, without));
          if (gain > 1e-9 && (!best || gain > best.gain)) {
            best = { t, tp, nt, ntp: without, gain, B, via: "absorbed", touched: keysOf([Bstop]) };
          }
        }
        // (b) it's full: trade one of its stops to the middle's truck, take B instead
        for (const S of routes[t]) {
          if (S.pin !== undefined) continue;
          if (loadOf(routes[t]) - S.orders + Bstop.orders > cap(t)) continue;
          if (loadOf(routes[tp]) - Bstop.orders + S.orders > cap(tp)) continue;
          const nt = cheapestInsert(sub, routes[t].filter((x) => x.nbhd !== S.nbhd), Bstop);
          const ntp = cheapestInsert(sub, without, S);
          const gain = base - (tidiedCost(sub, nt) + tidiedCost(sub, ntp));
          if (gain > 1e-9 && (!best || gain > best.gain)) {
            best = { t, tp, nt, ntp, gain, B, via: `trading ${S.nbhd}`, touched: keysOf([Bstop, S]) };
          }
        }
        // (c) split-swap: B is too big to take whole, but T drives THROUGH it — hand a
        //     detour stop X to B's truck and carve a slice of B back onto T. The slice
        //     size is FREE: carve as many of B's houses as capacity allows, not just
        //     X.orders. The capacity-neutral X-sized carve is a special case in range;
        //     letting the slice run heavier is the S14 fix (a 7/1 split wins where the
        //     neutral 6/2 loses). Both trucks are held within cap by the k bounds.
        //     (S2: Redmond ↔ half of Factoria; S4: Eastlake ↔ most of Mercer N.)
        for (const X of routes[t]) {
          if (X.pin !== undefined) continue;
          const kMin = Math.max(1, loadOf(routes[tp]) - cap(tp) + X.orders); // leave tp within cap
          const kMax = Math.min(Bstop.orders - 1, cap(t) - loadOf(routes[t]) + X.orders); // keep t within cap, leave ≥1 on B
          const lo = shackle ? Math.max(kMin, X.orders) : kMin;
          const hi = shackle ? Math.min(kMax, X.orders) : kMax;
          for (let k = lo; k <= hi; k++) {
            const take: Stop = { nbhd: B, orders: k, houses: Bstop.houses.slice(0, k) };
            const rest: Stop = { nbhd: B, orders: Bstop.orders - k, houses: Bstop.houses.slice(k) };
            const nt = cheapestInsert(sub, routes[t].filter((s) => s !== X), take);
            const ntp = cheapestInsert(sub, routes[tp].map((s) => (s.nbhd === B ? rest : s)), X);
            const gain = base - (tidiedCost(sub, nt) + tidiedCost(sub, ntp));
            if (gain > 1e-9 && (!best || gain > best.gain)) {
              best = { t, tp, nt, ntp, gain, B, via: `split ${k}/${Bstop.orders - k}, trading ${X.nbhd}`, touched: keysOf([X, take]) };
            }
          }
        }
      }
    }
    if (!best) break;
    routes[best.t] = best.nt;
    routes[best.tp] = best.ntp;
    log.push({ kind: "corridor", saved: best.gain, detail: `consolidated ${best.B} onto the truck passing through (${best.via})`, frame: snapshot(routes), touched: best.touched });
  }
}

/**
 * Post-slot local search — the final relocate + swap pass, on the SLOTTED routes.
 *
 * `orOpt` (relocate) and `exchange` (swap) run only on the pre-slot clusters. But the
 * slot-assignment + spill stage that follows can hand a slot a split half on a worse
 * truck than another slot could serve it from — an improvable assignment that no later
 * pass sees, because the one pass that does run post-slot (`corridorRepair`) only
 * consolidates *threaded* middles. So we re-run general relocate/swap here, with two
 * differences the slotted world demands:
 *   - EXACT slot caps `TRUCK_CAPS[i]` (the route IS its slot now; `capOf`'s optimistic
 *     MAX_CAP for an anchor-less route could overfill an east-12 truck);
 *   - positional routes — a slot emptied by a relocate stays in place (a truck that
 *     stayed home), never filtered out.
 * Scored on `tidiedCost` (the order the route settles into, the S14 discipline) and
 * accepting only gain > 0, so it is provably never-worse than the corridor-race result.
 */
function postSlotLocalSearch(sub: Substrate, bySlot: Stop[][], log: Move[]): void {
  const n = bySlot.length;
  for (let guard = 0; guard < 200; guard++) {
    type Best = { kind: "or-opt" | "swap"; a: number; b: number; ra: Stop[]; rb: Stop[]; gain: number; touched: string[] };
    let best: Best | null = null;
    const cost = (i: number) => tidiedCost(sub, bySlot[i]);

    // Relocate: move one stop a → b (coalescing if b already serves that neighborhood).
    for (let a = 0; a < n; a++) {
      if (bySlot[a].length === 0) continue;
      for (const stop of bySlot[a]) {
        if (stop.pin !== undefined) continue;
        for (let b = 0; b < n; b++) {
          if (b === a) continue;
          if (loadOf(bySlot[b]) + stop.orders > TRUCK_CAPS[b]) continue;
          const ra = bySlot[a].filter((x) => x !== stop);
          const rb = cheapestInsert(sub, bySlot[b], stop);
          const gain = cost(a) + cost(b) - (tidiedCost(sub, ra) + tidiedCost(sub, rb));
          if (gain > 1e-6 && (!best || gain > best.gain)) best = { kind: "or-opt", a, b, ra, rb, gain, touched: keysOf([stop]) };
        }
      }
    }
    // Swap: trade one stop between two slots when neither can simply receive a relocate.
    for (let a = 0; a < n; a++)
      for (let b = a + 1; b < n; b++) {
        if (bySlot[a].length === 0 || bySlot[b].length === 0) continue;
        for (let i = 0; i < bySlot[a].length; i++) {
          const sa = bySlot[a][i];
          if (sa.pin !== undefined) continue;
          for (let j = 0; j < bySlot[b].length; j++) {
            const sb = bySlot[b][j];
            if (sb.pin !== undefined || sa.nbhd === sb.nbhd) continue;
            if (loadOf(bySlot[a]) - sa.orders + sb.orders > TRUCK_CAPS[a]) continue;
            if (loadOf(bySlot[b]) - sb.orders + sa.orders > TRUCK_CAPS[b]) continue;
            const ra = coalesceStops(reinsert(sub, bySlot[a], i, sb));
            const rb = coalesceStops(reinsert(sub, bySlot[b], j, sa));
            const gain = cost(a) + cost(b) - (tidiedCost(sub, ra) + tidiedCost(sub, rb));
            if (gain > 1e-6 && (!best || gain > best.gain)) best = { kind: "swap", a, b, ra, rb, gain, touched: keysOf([sa, sb]) };
          }
        }
      }

    if (!best) break;
    bySlot[best.a] = best.ra;
    bySlot[best.b] = best.rb;
    const detail = best.kind === "or-opt" ? `relocated a stop to truck ${best.b + 1}` : `traded a stop between trucks ${best.a + 1} and ${best.b + 1}`;
    log.push({ kind: best.kind, saved: best.gain, detail, frame: snapshot(bySlot), touched: best.touched });
  }
}

/**
 * Arc-rebalance — a compound move the plain relocate/swap can't reach. A swap (or
 * relocate) that the EXACT slot caps would block is rescued by shifting ONE ARC of a
 * filler from the overfull truck to the other, so a heavy neighborhood can rejoin its
 * natural cluster while a small filler splits to absorb the overflow (the S493
 * Medina↔Redmond rescued by a Bellevue arc). Arcs come from `arcGroups`, so exempt /
 * cul-de-sac neighborhoods never split. Scored on `tidiedCost`, accepting only gain > 0
 * — provably never-worse, and the race keeps the min across variants. The win is a
 * two-step combination whose intermediate state isn't improving, so single-move greedy
 * (postSlotLocalSearch) can't cross to it; this evaluates the pair atomically.
 */
type ArcCand = { a: number; b: number; ra: Stop[]; rb: Stop[]; gain: number; touched: string[] };
function arcRebalance(sub: Substrate, bySlot: Stop[][], log: Move[]): void {
  const n = bySlot.length;
  const cost = (st: Stop[]) => tidiedCost(sub, st);
  for (let guard = 0; guard < 200; guard++) {
    let best: ArcCand | null = null;
    const score = (a: number, b: number, ra: Stop[], rb: Stop[], touched: string[]): void => {
      if (loadOf(ra) > TRUCK_CAPS[a] || loadOf(rb) > TRUCK_CAPS[b]) return;
      const gain = cost(bySlot[a]) + cost(bySlot[b]) - (cost(ra) + cost(rb));
      if (gain > 1e-6 && (!best || gain > best.gain)) best = { a, b, ra, rb, gain, touched };
    };
    // A base candidate (ra0 on a, rb0 on b). If it overfills exactly one side, try to
    // rescue it by arc-shifting a filler from the overfull side to the other.
    const withRescue = (a: number, b: number, ra0: Stop[], rb0: Stop[], touched: string[]): void => {
      const la = loadOf(ra0);
      const lb = loadOf(rb0);
      if (la <= TRUCK_CAPS[a] && lb <= TRUCK_CAPS[b]) { score(a, b, ra0, rb0, touched); return; }
      const overA = la > TRUCK_CAPS[a] && lb <= TRUCK_CAPS[b];
      const overB = lb > TRUCK_CAPS[b] && la <= TRUCK_CAPS[a];
      if (!overA && !overB) return; // both over — one arc can't fix it
      const over = overA ? ra0 : rb0;
      const under = overA ? rb0 : ra0;
      const capUnder = overA ? TRUCK_CAPS[b] : TRUCK_CAPS[a];
      const need = loadOf(over) - (overA ? TRUCK_CAPS[a] : TRUCK_CAPS[b]);
      for (const F of over) {
        if (F.pin !== undefined) continue;
        for (const arc of arcGroups(F.nbhd, F.houses)) {
          if (arc.length < need || arc.length >= F.orders) continue; // relieve enough, leave a remainder
          if (loadOf(under) + arc.length > capUnder) continue;
          const set = new Set(arc);
          const keep = F.houses.filter((h) => !set.has(h));
          const newOver = coalesceStops(over.map((s) => (s === F ? { ...s, orders: keep.length, houses: keep } : s)).filter((s) => s.houses.length));
          const newUnder = cheapestInsert(sub, under, { nbhd: F.nbhd, orders: arc.length, houses: arc });
          score(a, b, overA ? newOver : newUnder, overA ? newUnder : newOver, [...touched, ...keys(F.nbhd, arc)]);
        }
      }
    };
    for (let a = 0; a < n; a++) {
      if (bySlot[a].length === 0) continue;
      for (const stop of bySlot[a]) {
        if (stop.pin !== undefined) continue;
        for (let b = 0; b < n; b++) {
          if (b === a) continue;
          withRescue(a, b, bySlot[a].filter((x) => x !== stop), cheapestInsert(sub, bySlot[b], stop), keysOf([stop]));
        }
      }
    }
    for (let a = 0; a < n; a++)
      for (let b = a + 1; b < n; b++) {
        if (bySlot[a].length === 0 || bySlot[b].length === 0) continue;
        for (let i = 0; i < bySlot[a].length; i++) {
          const sa = bySlot[a][i];
          if (sa.pin !== undefined) continue;
          for (let j = 0; j < bySlot[b].length; j++) {
            const sb = bySlot[b][j];
            if (sb.pin !== undefined || sa.nbhd === sb.nbhd) continue;
            withRescue(a, b, coalesceStops(reinsert(sub, bySlot[a], i, sb)), coalesceStops(reinsert(sub, bySlot[b], j, sa)), keysOf([sa, sb]));
          }
        }
      }
    const pick = best as ArcCand | null; // best is only ever assigned inside `score` (a closure), so CFA narrows it to null here; cast restores the real type
    if (!pick) break;
    bySlot[pick.a] = pick.ra;
    bySlot[pick.b] = pick.rb;
    log.push({ kind: "or-opt", saved: pick.gain, detail: `arc-rebalance between trucks ${pick.a + 1} and ${pick.b + 1}`, frame: snapshot(bySlot), touched: pick.touched });
  }
}

/**
 * Entry/exit ring angles of the route's delivery visit to `nbhd` — the first time
 * the driven path reaches it (a later re-thread only transits). The gates are set
 * by the neighboring stops, NOT by which houses are delivered, so they're stable
 * as tidySplitHouses swaps house identities below. Null if the route never delivers it.
 */
function deliveryGates(sub: Substrate, stops: Stop[], nbhd: string): { entry: number; exit: number } | null {
  const nodes = pathNodes(sub, stops);
  for (let i = 1; i < nodes.length - 1; i++) {
    if (nodes[i] !== nbhd) continue;
    return { entry: gateAngle(nbhd, nodeAt(nodes[i - 1])), exit: gateAngle(nbhd, nodeAt(nodes[i + 1])) };
  }
  return null;
}

type SplitPart = { stop: Stop; gates: { entry: number; exit: number } };

/**
 * House-level tidy for SPLIT neighborhoods. painOf charges a FLAT ring per
 * neighborhood (trig-free, house-blind), so when two trucks split a neighborhood
 * the solver has no signal for WHICH houses each takes — it can hand a helper
 * truck a far-side house when a near-gate one was free (the S5 "T5 dips to the
 * far-south Mercer N house while T8 passes it anyway" flaw). This pass swaps house
 * identities between trucks sharing a neighborhood whenever it shortens the real
 * ring-walk. A swap keeps each truck's tote count — hence its pain — identical, so
 * it's a pure, never-worse PHYSICAL-time tie-break the cost model cannot see.
 */
function tidySplitHouses(sub: Substrate, bySlot: Stop[][]): void {
  const slotsByNbhd = new Map<string, number[]>();
  for (let i = 0; i < bySlot.length; i++)
    for (const s of bySlot[i])
      if (s.houses.length) (slotsByNbhd.get(s.nbhd) ?? slotsByNbhd.set(s.nbhd, []).get(s.nbhd)!).push(i);

  for (const [nbhd, slots] of slotsByNbhd) {
    if (slots.length < 2) continue; // not split — nothing to trade
    const parts: SplitPart[] = [];
    for (const slot of slots) {
      const stop = bySlot[slot].find((s) => s.nbhd === nbhd)!;
      const gates = deliveryGates(sub, bySlot[slot], nbhd);
      if (gates) parts.push({ stop, gates });
    }
    if (parts.length < 2) continue;
    const cost = (p: SplitPart) => localMinutes(nbhd, p.gates.entry, p.gates.exit, houseAngles(nbhd, p.stop.houses));

    // Swap one house between two sharing trucks while it shortens the combined walk.
    for (;;) {
      let best: { p: SplitPart; q: SplitPart; ai: number; bi: number; gain: number } | null = null;
      for (let x = 0; x < parts.length; x++)
        for (let y = x + 1; y < parts.length; y++) {
          const p = parts[x];
          const q = parts[y];
          const base = cost(p) + cost(q);
          for (let ai = 0; ai < p.stop.houses.length; ai++)
            for (let bi = 0; bi < q.stop.houses.length; bi++) {
              const a = p.stop.houses[ai];
              const b = q.stop.houses[bi];
              p.stop.houses[ai] = b;
              q.stop.houses[bi] = a;
              const gain = base - (cost(p) + cost(q));
              p.stop.houses[ai] = a; // restore; the best swap is applied once, after the scan
              q.stop.houses[bi] = b;
              if (gain > 1e-6 && (!best || gain > best.gain)) best = { p, q, ai, bi, gain };
            }
        }
      if (!best) break;
      const a = best.p.stop.houses[best.ai];
      best.p.stop.houses[best.ai] = best.q.stop.houses[best.bi];
      best.q.stop.houses[best.bi] = a;
    }
  }
}

/** Population stdev of a set of route times — our (im)balance measure. */
function stdev(times: number[]): number {
  if (times.length === 0) return 0;
  const mean = times.reduce((a, b) => a + b, 0) / times.length;
  return Math.sqrt(times.reduce((a, t) => a + (t - mean) ** 2, 0) / times.length);
}

/**
 * Free tie-breaks: relocate a single stop to another truck when total driver
 * time is unchanged (within a minute) but the route-time spread shrinks — the
 * "give the tied neighborhood to the lighter truck" move. It never lengthens the
 * day, so it runs unconditionally. There is no paid balancing: we minimize total
 * driver time alone, and uneven route lengths are a feature, not a bug.
 */
function rebalance(sub: Substrate, routes: Stop[][], log: Move[]): void {
  const TIE = 0.75; // minutes treated as "no change in total time"
  for (let guard = 0; guard < 400; guard++) {
    const times = routes.map((r) => costOf(sub, r));
    const spread0 = stdev(times.filter((_, i) => routes[i].length > 0));

    type Cand = { r: number; s: number; t: number; pos: number; dTotal: number; dSpread: number };
    let pick: Cand | null = null;

    for (let r = 0; r < routes.length; r++) {
      for (let s = 0; s < routes[r].length; s++) {
        const stop = routes[r][s];
        if (stop.pin !== undefined) continue; // a frozen anchor seed never relocates
        const without = [...routes[r].slice(0, s), ...routes[r].slice(s + 1)];
        const newRcost = costOf(sub, without);
        for (let t = 0; t < routes.length; t++) {
          if (t === r) continue;
          if (loadOf(routes[t]) + stop.orders > capOf(routes[t])) continue;
          for (let pos = 0; pos <= routes[t].length; pos++) {
            const newTcost = costOf(sub, [...routes[t].slice(0, pos), stop, ...routes[t].slice(pos)]);
            const dTotal = newRcost - times[r] + (newTcost - times[t]);
            if (Math.abs(dTotal) > TIE) continue; // tie-breaks only — never lengthen the day
            const nt = times.slice();
            nt[r] = newRcost;
            nt[t] = newTcost;
            const after = nt.filter((_, i) => (i === r ? without.length > 0 : true) && routes[i].length > 0);
            const dSpread = stdev(after) - spread0;
            if (dSpread >= -1e-6) continue; // and only when they actually even out
            if (!pick || dSpread < pick.dSpread) pick = { r, s, t, pos, dTotal, dSpread };
          }
        }
      }
    }

    if (!pick) break;
    const stop = routes[pick.r][pick.s];
    routes[pick.r] = [...routes[pick.r].slice(0, pick.s), ...routes[pick.r].slice(pick.s + 1)];
    routes[pick.t] = [...routes[pick.t].slice(0, pick.pos), stop, ...routes[pick.t].slice(pick.pos)];
    log.push({ kind: "balance", saved: -pick.dTotal, detail: `tie-break: ${stop.nbhd} → another truck`, frame: snapshot(routes), touched: keysOf([stop]) });
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
  const maxK = Math.min(3, houses.length - 1);
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
 * to a SECOND truck when doing so lowers total driver time. Never forced —
 * splitting adds a second truck's ring driving, so it only happens when capacity
 * relief or geometry more than pays for it.
 */
function splitPass(sub: Substrate, routes: Stop[][], log: Move[]): void {
  for (let guard = 0; guard < 60; guard++) {
    const times = routes.map((r) => costOf(sub, r));

    type Cand = { a: number; sa: number; b: number; pos: number; S: number[]; rest: number[]; g: number };
    let pick: Cand | null = null;

    for (let a = 0; a < routes.length; a++) {
      for (let sa = 0; sa < routes[a].length; sa++) {
        if (routes[a][sa].pin !== undefined) continue; // a frozen anchor seed never splits off
        const N = routes[a][sa].nbhd;
        const H = routes[a][sa].houses;
        if (H.length < 2) continue;
        const subsets = arcSubsets(N, H);
        for (let b = 0; b < routes.length; b++) {
          if (b === a || routes[b].some((s) => s.nbhd === N)) continue;
          for (const S of subsets) {
            if (loadOf(routes[b]) + S.length > capOf(routes[b])) continue;
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
            const g = costA - times[a] + (bestB - times[b]); // Δ total driver time
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
    log.push({ kind: "balance", saved: -pick.g, detail: `split ${N}: ${pick.S.length} of ${pick.S.length + pick.rest.length} totes to another truck`, frame: snapshot(routes), touched: keys(N, pick.S) });
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
      if (s.pin !== undefined) existing.pin = s.pin; // a seed + its overflow → keep the slot
    } else {
      const copy: Stop = { nbhd: s.nbhd, orders: s.houses.length, houses: [...s.houses], pin: s.pin };
      byNbhd.set(s.nbhd, copy);
      out.push(copy);
    }
  }
  return out;
}

/** Total fleet pain of a plan — the integer objective the solver minimizes. */
function planPain(sub: Substrate, plan: Plan): number {
  return plan.routes.reduce((s, r) => s + painOf(sub, r.stops), 0);
}

// Medina deferred (today) vs Medina free. Deferring Medina is a per-shift coin-flip
// (helps ~37%, no local signal — it's mediated by global packing), so we race it.
const DEFER_NO_MEDINA = new Set([...DEFER_SET].filter((n) => n !== "Medina"));

/**
 * The construction race: each variant is a per-shift coin-flip with no local signal,
 * so we solve all and keep the cheapest by pain. Every variant is a legal full solve,
 * so the min is never worse than any single one — and today's behavior is variant 0
 * (`room/whole`, Medina-deferred), so the race can never regress it. Order matters: a
 * tie resolves to the FIRST listed (strict `<` below), so variant 0 stays the default
 * and the result is deterministic.
 *   - split:  leftover-packing — `room` (roomiest truck, biggest chunk, geography-blind)
 *             vs `cost` (cheapest truck, cheapest chunk).
 *   - arc:    free clusters — `whole` (one lot per neighborhood) vs `arc` (one lot per
 *             ring arc, so a passing truck grabs the near arc instead of the capacity
 *             auction handing the whole neighborhood to whoever has room — the S487 fix).
 *   - medina: `M+` (deferred with the FC-adjacent fillers) vs `M-` (free in construction).
 */
type Variant = { label: string; costAware: boolean; arcSplit: boolean; defer: Set<string> };
const RACE: Variant[] = [];
for (const [stag, costAware] of [["room", false] as const, ["cost", true] as const])
  for (const [atag, arcSplit] of [["whole", false] as const, ["arc", true] as const])
    for (const [mtag, defer] of [["M+", DEFER_SET] as const, ["M-", DEFER_NO_MEDINA] as const])
      RACE.push({ label: `${stag}/${atag}/${mtag}`, costAware, arcSplit, defer });

/** Run the full race; return the cheapest plan, plus each variant's pain for diagnostics. */
export function race(sub: Substrate, orders: Map<string, number[]>, allowSplit = true): { best: Plan; winner: string; pains: { label: string; pain: number }[] } {
  let best: Plan | null = null;
  let bestPain = Infinity;
  let winner = "";
  const pains: { label: string; pain: number }[] = [];
  for (const v of RACE) {
    const plan = runSolve(sub, orders, allowSplit, v.costAware, v.defer, v.arcSplit);
    const pain = planPain(sub, plan);
    pains.push({ label: v.label, pain });
    if (pain < bestPain) {
      bestPain = pain;
      best = plan;
      winner = v.label;
    }
  }
  return { best: best!, winner, pains };
}

/** Plan the fleet for a day's orders. Deterministic — same orders, same plan. */
export function solve(sub: Substrate, orders: Map<string, number[]>, allowSplit = true): Plan {
  return race(sub, orders, allowSplit).best;
}

function runSolve(sub: Substrate, orders: Map<string, number[]>, allowSplit: boolean, costAware: boolean, deferSet: Set<string>, arcSplit: boolean): Plan {
  const log: Move[] = [];
  const all = customers(orders, arcSplit);
  const deferred = all.filter((c) => deferSet.has(c.nbhd)); // FC-adjacent fillers, placed last
  const routes: Stop[][] = all.filter((c) => !deferSet.has(c.nbhd)).map((c) => [c]);
  const seed = snapshot(routes); // the starting picture: each neighborhood its own cluster

  construct(sub, routes, log, false); // savings merges while they help
  if (routes.length > FLEET.trucks) construct(sub, routes, log, true); // squeeze into the fleet
  if (routes.length > FLEET.trucks) forcePlace(sub, routes, log, costAware); // pack the capacity-fragmented residue
  placeDeferred(sub, routes, deferred, log, costAware); // now slot the cheap FC-adjacent demand into leftover slack

  for (const r of routes) twoOpt(sub, r, log);
  orOpt(sub, routes, log);
  exchange(sub, routes, log); // trade stops between trucks too full to accept a relocation
  for (const r of routes) twoOpt(sub, r, log); // re-tidy after relocations

  rebalance(sub, routes, log); // free tie-breaks (never lengthen the day)
  if (allowSplit) {
    splitPass(sub, routes, log); // voluntary split delivery, if it lowers total time
    exchange(sub, routes, log); // a split can leave a neighborhood crossed between two trucks; the
    // consolidating swap (re-merge it onto its corridor truck) only exists AFTER splitPass creates it
    rebalance(sub, routes, log); // re-settle with any split in place
  }
  for (let i = 0; i < routes.length; i++) routes[i] = coalesceStops(routes[i]); // one stop per neighborhood
  for (const r of routes) twoOpt(sub, r, log); // tidy any route the passes reshaped

  const unrouted: Stop[] = [];
  while (routes.length > FLEET.trucks) unrouted.push(...routes.pop()!);

  // Lay each route into its truck slot: an anchored route owns its anchor's slot
  // (so Truck 1 is always the West Seattle truck), and any anchor-less leftover
  // fills an empty (idle-anchor) slot. We always emit all FLEET.trucks slots, in
  // order — an empty one is just a truck that stayed home today.
  const bySlot: Stop[][] = Array.from({ length: FLEET.trucks }, () => []);
  const leftover: Stop[][] = [];
  for (const r of routes) {
    if (r.length === 0) continue;
    const anchor = r.find((s) => s.pin !== undefined);
    if (anchor) bySlot[anchor.pin!] = r;
    else leftover.push(r);
  }
  leftover.sort((a, b) => loadOf(b) - loadOf(a)); // place the biggest clusters first
  for (const r of leftover) {
    // Prefer an idle slot that can hold the whole cluster (caps differ by side).
    const whole = bySlot.findIndex((slot, i) => slot.length === 0 && loadOf(r) <= TRUCK_CAPS[i]);
    if (whole >= 0) {
      bySlot[whole] = r;
      continue;
    }
    // No idle slot fits it whole (e.g. a 13-tote west cluster, but the only idle
    // truck is an east 12-cap one). Spill it across slots with room, splitting a
    // stop if we must — total capacity exceeds demand, so this always lands.
    for (const stop of r) {
      let houses = stop.houses;
      while (houses.length) {
        let best = -1;
        let room = 0;
        for (let i = 0; i < bySlot.length; i++) {
          const free = TRUCK_CAPS[i] - loadOf(bySlot[i]);
          if (free > room) {
            room = free;
            best = i;
          }
        }
        if (best < 0 || room <= 0) {
          unrouted.push({ nbhd: stop.nbhd, orders: houses.length, houses }); // truly no room (shouldn't happen)
          break;
        }
        const take = houses.slice(0, room);
        houses = houses.slice(room);
        bySlot[best].push({ nbhd: stop.nbhd, orders: take.length, houses: take });
      }
    }
  }

  // Final consolidation on the SLOTTED routes, with exact per-slot caps. The spill
  // above can hand a slot a cluster whose truck now drives THROUGH a neighborhood
  // another slot serves — the "I pass it every day, why am I sent elsewhere?" fix.
  for (let i = 0; i < bySlot.length; i++) bySlot[i] = coalesceStops(bySlot[i]);
  // Race two corridor passes on the slotted routes and keep the cheaper: a CONSERVATIVE
  // one (capacity-neutral split-swaps only) and an AGGRESSIVE one (free-slice splits — the
  // S14 7/1 fix). The conservative pass is never worse than skipping consolidation, so the
  // min of the two is never worse than that baseline; the aggressive free-slice split wins
  // only on shifts where it genuinely helps, never where greedy myopia would misfire.
  const cons = snapshot(bySlot);
  const consLog: Move[] = [];
  corridorRepair(sub, cons, consLog, (i) => TRUCK_CAPS[i], true);
  const aggr = snapshot(bySlot);
  const aggrLog: Move[] = [];
  corridorRepair(sub, aggr, aggrLog, (i) => TRUCK_CAPS[i], false);
  const painSum = (rs: Stop[][]): number => rs.reduce((a, r) => a + tidiedCost(sub, r), 0);
  const winner = painSum(aggr) < painSum(cons) ? { rs: aggr, lg: aggrLog } : { rs: cons, lg: consLog };
  bySlot.splice(0, bySlot.length, ...winner.rs);
  for (const m of winner.lg) log.push(m);
  for (const r of bySlot) twoOpt(sub, r, log); // re-tidy the routes a consolidation reshaped

  // General relocate/swap on the slotted routes — catches improvements the slot
  // assignment + spill created, which the pre-slot orOpt/exchange never saw.
  postSlotLocalSearch(sub, bySlot, log);
  for (const r of bySlot) twoOpt(sub, r, log);

  // Arc-rebalance: compound swap/relocate moves rescued by an arc-shift — lets a heavy
  // neighborhood rejoin its cluster while a small filler splits to make room (S493).
  arcRebalance(sub, bySlot, log);
  for (const r of bySlot) twoOpt(sub, r, log);

  // Final, pain-neutral polish: hand each split neighborhood's helper truck its
  // near-gate houses (the flat ring cost is blind to which houses; the real drive isn't).
  tidySplitHouses(sub, bySlot);

  const built: Route[] = bySlot.map((stops) => {
    const b = breakdown(sub, stops);
    return { stops, orders: loadOf(stops), travel: b.travel, time: b.time };
  });

  const total = built.reduce(
    (acc, r) => {
      const b = breakdown(sub, r.stops);
      return { travel: acc.travel + b.travel, local: acc.local + b.local, service: acc.service + b.service };
    },
    { travel: 0, local: 0, service: 0 },
  );

  // Spread is measured over the trucks actually out (an idle truck isn't a 0-min
  // route, it's no route) so it stays a meaningful read of deployed imbalance.
  const ts = built.filter((r) => r.stops.length > 0).map((r) => r.time);
  const spread = ts.length ? Math.max(...ts) - Math.min(...ts) : 0;

  // Replay reel: the seed, every pair-changing move in order, then the final
  // plan once routes are slotted to their trucks (the honest "snap to lanes").
  const tag = { merge: "merge", "2-opt": "reorder", "or-opt": "relocate", swap: "swap", balance: "settle", corridor: "consolidate" } as const;
  const captionOf = (m: Move): string => {
    const saved = m.saved > 0.5 ? `  −${Math.round(m.saved)} pain` : "";
    return `${tag[m.kind]} · ${m.detail}${saved}`;
  };
  const frames: SolveFrame[] = [
    { routes: seed.map((stops) => ({ stops })), touched: [], label: `start · ${seed.length} clusters seeded` },
    ...log
      .filter((m) => m.frame)
      .map((m) => ({ routes: m.frame!.map((stops) => ({ stops })), touched: m.touched ?? [], label: captionOf(m) })),
    { routes: built.map((r) => ({ stops: r.stops })), touched: [], label: `done · trucks assigned to their lanes` },
  ];

  return {
    routes: built,
    totalTime: total.travel + total.local + total.service,
    travel: total.travel,
    local: total.local,
    service: total.service,
    spread,
    log,
    frames,
    unrouted,
  };
}
