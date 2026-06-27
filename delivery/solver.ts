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
// Those three are the real minutes (route.time, the playback clock). The SOLVER
// minimizes one thing more: TOTE-MINUTES — every tote still on board accrues cost
// each minute until it's delivered (heavy truck = fuel + a waiting customer). It
// rides on top of physical time as `time + CARRY_COST * toteMin`, weighting "drop
// weight early / serve close customers soon" against raw distance. It never leaks
// into reported times — those read `breakdown` straight.
//
// LOCAL depends on the entry/exit gates, so it depends on the route's *shape* —
// which means reordering a route, or which truck takes a neighborhood, changes
// the cost. There's no flat per-visit charge; the slow ring geometry itself does
// the consolidation-deterrence (two trucks each pay their own ring driving).
//
// Construction is Clarke–Wright savings (greedy best-merge); improvement is
// 2-opt within a route and Or-opt across routes. Every accepted move records a
// "saved N min" reason, for the manager-override phase to surface later.

import { FLEET, TRUCK_ANCHORS, TRUCK_CAPS, MAX_CAP, DEFER_LAST, gateAngle, houseAngles, nodeAt } from "./geography.ts";
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
  kind: "merge" | "2-opt" | "or-opt" | "swap" | "balance";
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

type Breakdown = { travel: number; local: number; service: number; time: number; toteMin: number };

/**
 * Full cost of a stop sequence. Expands the shortest path so every neighborhood
 * the truck actually drives through (delivered-to OR threaded) is priced with
 * the correct entry/exit gates. One walk also accumulates `toteMin` — the totes
 * still aboard, integrated over the time they're carried (load drops as the truck
 * delivers) — the solver's urgency term. `time` stays the physical day.
 */
function breakdown(sub: Substrate, stops: Stop[]): Breakdown {
  if (stops.length === 0) return { travel: 0, local: 0, service: 0, time: 0, toteMin: 0 };

  const waypoints = ["FC", ...stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    for (const node of sub.path(waypoints[i - 1], waypoints[i])) {
      if (nodes[nodes.length - 1] !== node) nodes.push(node);
    }
  }

  const houses = housesByNbhd(stops);
  // A neighborhood drives its full delivery ring ONCE (at its first occurrence);
  // if the shortest path threads back through it later, that pass costs only the
  // short gate-to-gate transit arc — you don't re-loop a town you already did.
  const delivered = new Set<string>();
  let travel = 0;
  let local = 0;
  let toteMin = 0;
  let aboard = loadOf(stops); // totes still on the truck (all of them, leaving the FC)
  for (let i = 1; i < nodes.length; i++) {
    const seg = sub.time(nodes[i - 1], nodes[i]);
    travel += seg;
    toteMin += aboard * seg; // every tote still aboard pays for this artery leg
    const node = nodes[i];
    if (node === "FC" || i >= nodes.length - 1) continue;
    const full = houses.get(node);
    const visit = full && full.length && !delivered.has(node) ? full : [];
    const entry = gateAngle(node, nodeAt(nodes[i - 1]));
    const exit = gateAngle(node, nodeAt(nodes[i + 1]));
    const lm = localMinutes(node, entry, exit, houseAngles(node, visit));
    local += lm;
    toteMin += aboard * lm; // and for the slow ring drive
    if (visit.length) {
      delivered.add(node);
      aboard -= visit.length; // dropped here, so lighter from now on
    }
  }

  const service = loadOf(stops) * SERVICE;
  return { travel, local, service, time: travel + local + service, toteMin };
}

// How much a tote-minute (one tote carried one minute) costs against a plain
// driver-minute — the N/M ratio. At 0.1 the solver will accept ~10 min of extra
// driving to spare a tote ~100 tote-minutes of riding, which is what pulls a
// close-but-last customer (Factoria) up to an early, fresh delivery.
const CARRY_COST = 0.3;
const costOf = (sub: Substrate, stops: Stop[]): number => {
  const b = breakdown(sub, stops);
  return b.time + CARRY_COST * b.toteMin;
};

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
function customers(orders: Map<string, number[]>): Stop[] {
  const out: Stop[] = [];
  const free = (nbhd: string, idx: number[]): void => {
    for (let i = 0; i < idx.length; i += CAP) {
      const houses = idx.slice(i, i + CAP);
      out.push({ nbhd, orders: houses.length, houses });
    }
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
function forcePlace(sub: Substrate, routes: Stop[][], log: Move[]): void {
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
        // No single truck fits it whole — drop a chunk on the roomiest and loop.
        let into: Stop[] | null = null;
        let room = 0;
        for (const k of kept) {
          const free = capOf(k) - loadOf(k);
          if (free > room) {
            room = free;
            into = k;
          }
        }
        if (!into || room <= 0) throw new Error("forcePlace: no truck has room — demand exceeds fleet capacity"); // unreachable: 84 ≤ 96
        const take = remaining.slice(0, room);
        remaining = remaining.slice(room);
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
function placeDeferred(sub: Substrate, routes: Stop[][], deferred: Stop[], log: Move[]): void {
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
      // No single truck fits it whole — drop a chunk on the roomiest and loop.
      let room = 0;
      let ri = -1;
      for (let k = 0; k < routes.length; k++) {
        const free = capOf(routes[k]) - loadOf(routes[k]);
        if (free > room) {
          room = free;
          ri = k;
        }
      }
      if (ri < 0 || room <= 0) throw new Error("placeDeferred: no truck has room — demand exceeds fleet capacity");
      const take = remaining.slice(0, room);
      remaining = remaining.slice(room);
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

/** Plan the fleet for a day's orders. Deterministic — same orders, same plan. */
export function solve(sub: Substrate, orders: Map<string, number[]>, allowSplit = true): Plan {
  const log: Move[] = [];
  const all = customers(orders);
  const deferred = all.filter((c) => DEFER_SET.has(c.nbhd)); // FC-adjacent fillers, placed last
  const routes: Stop[][] = all.filter((c) => !DEFER_SET.has(c.nbhd)).map((c) => [c]);
  const seed = snapshot(routes); // the starting picture: each neighborhood its own cluster

  construct(sub, routes, log, false); // savings merges while they help
  if (routes.length > FLEET.trucks) construct(sub, routes, log, true); // squeeze into the fleet
  if (routes.length > FLEET.trucks) forcePlace(sub, routes, log); // pack the capacity-fragmented residue
  placeDeferred(sub, routes, deferred, log); // now slot the cheap FC-adjacent demand into leftover slack

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
  const tag = { merge: "merge", "2-opt": "reorder", "or-opt": "relocate", swap: "swap", balance: "settle" } as const;
  const captionOf = (m: Move): string => {
    const saved = m.saved > 0.5 ? `  −${Math.round(m.saved)} min` : "";
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
