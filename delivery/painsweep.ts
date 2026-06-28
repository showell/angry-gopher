// painsweep.ts — dev analysis. Sweep the first N shifts (S1, S2, …, the same
// seed chain the UI walks from seed 49) and rank them by total fleet PAIN — the
// integer cost the solver actually minimizes. The point is to find the single
// most painful day and decide whether it's a pathological order draw or a hole
// in the algorithm. Not in the browser bundle; run it with:
//
//   delivery/node_modules/.bin/esbuild delivery/painsweep.ts \
//     --bundle --platform=node --format=esm --outfile=/tmp/ps.mjs && node /tmp/ps.mjs
//
// Optional: pass a shift count as argv[2] (default 200).

import { buildSubstrate, edges } from "./roadgraph.ts";
import { race, painOf } from "./solver.ts";
import { chooseOrders, ordersByNeighborhood } from "./orders.ts";
import { FLEET, TRUCK_CAPS } from "./geography.ts";

const sub = buildSubstrate();

// West neighborhoods are everything not reached over a bridge — the warehouse is
// on the east shore, so "west" = the lake-crossers' territory. We classify by the
// anchor split (slots 1-5 west, 6-8 east) plus the bridge-side towns, to report a
// day's west/east demand balance — a likely pathology axis.
const EAST = new Set(["Bellevue", "Medina", "Kirkland", "Redmond", "Issaquah", "Factoria", "Mercer N", "Mercer S", "Mercer Island"]);

// The same LCG the UI uses to walk from one shift to the next (main.ts).
function shiftSeeds(n: number): number[] {
  const seeds: number[] = [];
  let seed = 49;
  for (let i = 0; i < n; i++) {
    seeds.push(seed);
    seed = (seed * 1664525 + 1013904223) >>> 0;
  }
  return seeds;
}

/** Total fleet pain — the honest objective, summed across every deployed truck. */
function planPain(routes: { stops: any[] }[]): number {
  return routes.reduce((s, r) => s + painOf(sub, r.stops), 0);
}

// Graph adjacency (surface roads + bridge segments), both directions.
const ADJ = new Map<string, Set<string>>();
for (const e of edges()) {
  (ADJ.get(e.a) ?? ADJ.set(e.a, new Set()).get(e.a)!).add(e.b);
  (ADJ.get(e.b) ?? ADJ.set(e.b, new Set()).get(e.b)!).add(e.a);
}

/**
 * Chain triplets A–B–C: B's two neighbors A,C that are NOT directly connected and
 * whose shortest path genuinely runs through B (B is a mandatory waypoint between
 * them). The skip-the-middle failure mode lives only on chains; triangles (A–C edge
 * present) are FLEX — skipping a node there is free and correct, never a bug.
 */
function chainTriplets(): { a: string; b: string; c: string }[] {
  const out: { a: string; b: string; c: string }[] = [];
  for (const [b, nbrs] of ADJ) {
    if (b === "FC" || b === "Mercer Island") continue; // FC isn't demand; Mercer Island has 0 houses
    const list = [...nbrs];
    for (let i = 0; i < list.length; i++)
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i], c = list[j];
        if (ADJ.get(a)?.has(c)) continue; // A–C edge ⇒ triangle ⇒ flex, not a chain
        if (sub.path(a, c).includes(b)) out.push({ a, b, c }); // B really is the waypoint
      }
  }
  return out;
}
const CHAINS = chainTriplets();

// The set of nodes that act as a chain-middle in at least one triplet (non-flex
// waypoints). A node also in a triangle still counts here only via its chain role.
const CHAIN_MIDS = new Set(CHAINS.map((t) => t.b));

/** The full node sequence a route drives: FC → stops → FC, shortest path expanded. */
function drivenNodes(stops: { nbhd: string }[]): string[] {
  const waypoints = ["FC", ...stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    for (const node of sub.path(waypoints[i - 1], waypoints[i])) if (nodes[nodes.length - 1] !== node) nodes.push(node);
  }
  return nodes;
}

type SkipFlag = { thru: number; mid: string; held: number };

/**
 * Skip-the-middle lint, two conditions BOTH required:
 *   (1) the truck's REAL driven path threads through B (it actually passes B's gate
 *       between two of its own stops — "holds both endpoints" alone is a false
 *       positive, since e.g. Bellevue is reached straight from the depot); and
 *   (2) B is a non-flex CHAIN MIDDLE (a mandatory waypoint, not a triangle node a
 *       truck can skip for free), with demand today held by a DIFFERENT truck.
 * corridorRepair is supposed to consolidate these; anything left is a candidate hole.
 */
function skipTheMiddle(routes: { stops: { nbhd: string }[] }[]): SkipFlag[] {
  const server = new Map<string, number>(); // who DELIVERS each nbhd
  routes.forEach((r, t) => r.stops.forEach((s) => server.set(s.nbhd, t)));
  const flags: SkipFlag[] = [];
  routes.forEach((r, t) => {
    if (r.stops.length === 0) return;
    const delivers = new Set(r.stops.map((s) => s.nbhd));
    const seen = new Set<string>();
    for (const node of drivenNodes(r.stops)) {
      if (node === "FC" || delivers.has(node) || seen.has(node) || !CHAIN_MIDS.has(node)) continue;
      seen.add(node);
      const owner = server.get(node);
      if (owner !== undefined && owner !== t) flags.push({ thru: t + 1, mid: node, held: owner + 1 });
    }
  });
  return flags;
}

type ShiftResult = {
  shift: number;
  seed: number;
  pain: number;
  time: number;
  deployed: number;
  westDemand: number;
  eastDemand: number;
  routes: { slot: number; nbhds: string; orders: number; cap: number; pain: number; time: number }[];
  demand: [string, number][];
  skips: SkipFlag[];
  raw: S[][];
  winner: string;
  variantPains: { label: string; pain: number }[];
};

function runShift(shift: number, seed: number): ShiftResult {
  const orders = chooseOrders(seed, FLEET.orders);
  const byNbhd = ordersByNeighborhood(orders);
  const { best: plan, winner, pains: variantPains } = race(sub, byNbhd);

  let westDemand = 0;
  let eastDemand = 0;
  for (const [nbhd, houses] of byNbhd) (EAST.has(nbhd) ? (eastDemand += houses.length) : (westDemand += houses.length));

  const routes = plan.routes
    .map((r, i) => ({
      slot: i + 1,
      nbhds: r.stops.map((s) => `${s.nbhd}(${s.orders})`).join(" → "),
      orders: r.orders,
      cap: TRUCK_CAPS[i],
      pain: Math.round(painOf(sub, r.stops)),
      time: Math.round(r.time),
    }))
    .filter((r) => r.orders > 0);

  return {
    shift,
    seed,
    pain: Math.round(planPain(plan.routes)),
    time: Math.round(plan.totalTime),
    deployed: routes.length,
    westDemand,
    eastDemand,
    demand: [...byNbhd.entries()].map(([n, h]) => [n, h.length] as [string, number]).sort((a, b) => b[1] - a[1]),
    routes,
    skips: skipTheMiddle(plan.routes),
    raw: plan.routes.map((r) => r.stops as S[]),
    winner,
    variantPains,
  };
}

// --- Cost-based optimality probe -------------------------------------------
// The honest hole-test: does ANY legal move actually lower pain? We respect the
// constraints the solver itself respects — pinned anchors don't relocate, slot
// caps hold — and we let a moved stop coalesce into a route already serving its
// nbhd (merge houses). Routes are tiny, so we brute-force each route's best stop
// ordering (the tidy the pipeline would realize) rather than trust insertion order.

type S = { nbhd: string; orders: number; houses: number[]; pin?: number };

/** Min pain over every ordering of a route's stops — the cost it can settle into. */
function bestPain(stops: S[]): number {
  if (stops.length <= 1) return painOf(sub, stops);
  let best = Infinity;
  const perm = (arr: S[], k: number) => {
    if (k === arr.length) { best = Math.min(best, painOf(sub, arr)); return; }
    for (let i = k; i < arr.length; i++) { [arr[k], arr[i]] = [arr[i], arr[k]]; perm(arr, k + 1); [arr[k], arr[i]] = [arr[i], arr[k]]; }
  };
  perm([...stops], 0);
  return best;
}

const load = (st: S[]) => st.reduce((s, c) => s + c.orders, 0);
/** A route's cap = its anchor's slot cap, else the generous max (matches solver capOf). */
const cap = (st: S[], slot: number) => {
  const anc = st.find((s) => s.pin !== undefined);
  return anc ? TRUCK_CAPS[anc.pin!] : TRUCK_CAPS[slot];
};
const merge = (st: S[], add: S): S[] => {
  const at = st.findIndex((s) => s.nbhd === add.nbhd);
  if (at < 0) return [...st, add];
  const c = [...st]; c[at] = { ...c[at], orders: c[at].orders + add.orders, houses: [...c[at].houses, ...add.houses] };
  return c;
};

type Improve = { kind: string; saved: number; detail: string };

/** Every improving relocate / swap the solver should have found but didn't. */
function optimalityProbe(routes: S[][]): Improve[] {
  const out: Improve[] = [];
  const base = routes.map((r) => bestPain(r));
  for (let i = 0; i < routes.length; i++) {
    for (let j = 0; j < routes.length; j++) {
      if (i === j || routes[i].length === 0) continue;
      // Relocate one stop i→j (skip pinned anchors; cap-respecting; coalesce ok).
      for (const s of routes[i]) {
        if (s.pin !== undefined) continue;
        const ni = routes[i].filter((x) => x !== s);
        const nj = merge(routes[j], s);
        if (load(nj) > cap(nj, j)) continue;
        const after = bestPain(ni) + bestPain(nj);
        const saved = base[i] + base[j] - after;
        if (saved > 1) out.push({ kind: "relocate", saved: Math.round(saved), detail: `move ${s.nbhd}(${s.orders}) T${i + 1}→T${j + 1}` });
      }
    }
  }
  // Swaps (i<j, both stops unpinned, caps hold after the trade).
  for (let i = 0; i < routes.length; i++)
    for (let j = i + 1; j < routes.length; j++)
      for (const a of routes[i]) {
        if (a.pin !== undefined) continue;
        for (const b of routes[j]) {
          if (b.pin !== undefined || a.nbhd === b.nbhd) continue;
          const ni = merge(routes[i].filter((x) => x !== a), b);
          const nj = merge(routes[j].filter((x) => x !== b), a);
          if (load(ni) > cap(ni, i) || load(nj) > cap(nj, j)) continue;
          const saved = base[i] + base[j] - (bestPain(ni) + bestPain(nj));
          if (saved > 1) out.push({ kind: "swap", saved: Math.round(saved), detail: `swap ${a.nbhd}(${a.orders}) T${i + 1} ↔ ${b.nbhd}(${b.orders}) T${j + 1}` });
        }
      }
  return out.sort((x, y) => y.saved - x.saved);
}

const N = 200; // shifts S1..S200 — the standing sweep size (no CLI knobs)
const seeds = shiftSeeds(N);
const results = seeds.map((seed, i) => runShift(i + 1, seed));

// --- Distribution of total pain across the N shifts -------------------------
const byPain = [...results].sort((a, b) => a.pain - b.pain);
const pains = byPain.map((r) => r.pain);
const q = (p: number) => pains[Math.min(pains.length - 1, Math.floor(p * pains.length))];
const mean = Math.round(pains.reduce((s, v) => s + v, 0) / pains.length);

console.log(`\n=== ${N} shifts (S1..S${N}), total fleet PAIN ===`);
console.log(`  min ${q(0)}   p25 ${q(0.25)}   median ${q(0.5)}   mean ${mean}   p75 ${q(0.75)}   p90 ${q(0.9)}   max ${pains[pains.length - 1]}`);

// --- Race variant scorecard: who wins, who never earns its slot -------------
// Two questions: (1) which variant produces the kept (min-pain) plan, and (2) is any
// variant a CONSISTENT LOSER we could prune? A variant earns its keep only when it is
// the SOLE achiever of a shift's best pain (drop it and that shift gets worse). We also
// check pairwise DOMINATION — variant A dominates B if A ≤ B on every shift — since a
// dominated variant is pure overhead. Tie at the min is credited to the first-listed
// variant (matches solve()'s deterministic keep-min), so "wins" sums to exactly N.
const labels = results[0].variantPains.map((v) => v.label);
const wins = new Map(labels.map((l) => [l, 0]));
const sole = new Map(labels.map((l) => [l, 0])); // shifts where this variant ALONE hits the min
for (const r of results) {
  const min = Math.min(...r.variantPains.map((v) => v.pain));
  wins.set(r.winner, wins.get(r.winner)! + 1);
  const atMin = r.variantPains.filter((v) => v.pain === min);
  if (atMin.length === 1) sole.set(atMin[0].label, sole.get(atMin[0].label)! + 1);
}
console.log(`\n=== RACE SCORECARD — ${labels.length} variants (split/arc/medina), ${N} shifts ===`);
console.log(`  variant          wins   sole-best   (sole = drop it and some shift regresses)`);
for (const l of labels)
  console.log(`  ${l.padEnd(14)} ${String(wins.get(l)).padStart(5)}   ${String(sole.get(l)).padStart(9)}${sole.get(l) === 0 ? "   ← never decisive (prune candidate)" : ""}`);

// Pairwise domination: A dominates B if A.pain ≤ B.pain on EVERY shift (and < on ≥1).
const painOfVar = (r: ShiftResult, l: string) => r.variantPains.find((v) => v.label === l)!.pain;
const dominated: string[] = [];
for (const b of labels) {
  for (const a of labels) {
    if (a === b) continue;
    let everyLE = true;
    let someLT = false;
    for (const r of results) {
      const pa = painOfVar(r, a);
      const pb = painOfVar(r, b);
      if (pa > pb) everyLE = false;
      if (pa < pb) someLT = true;
    }
    if (everyLE && someLT) {
      dominated.push(`${b}  dominated by  ${a}`);
      break;
    }
  }
}
console.log(`  domination: ${dominated.length ? dominated.join("; ") : "none — every variant wins some shift outright"}`);

const worst = byPain.slice(-12).reverse();
const best = byPain.slice(0, 3);
console.log(`\n  --- 12 MOST painful shifts ---`);
for (const r of worst) {
  const lop = r.westDemand - r.eastDemand;
  console.log(`  S${String(r.shift).padStart(3)}  pain ${String(r.pain).padStart(5)}  time ${String(r.time).padStart(4)}  ${r.deployed} trucks  W/E ${r.westDemand}/${r.eastDemand} (Δ${lop >= 0 ? "+" : ""}${lop})  seed ${r.seed}`);
}
console.log(`\n  --- 3 LEAST painful (for contrast) ---`);
for (const r of best) {
  console.log(`  S${String(r.shift).padStart(3)}  pain ${String(r.pain).padStart(5)}  time ${String(r.time).padStart(4)}  ${r.deployed} trucks  W/E ${r.westDemand}/${r.eastDemand}  seed ${r.seed}`);
}

// --- Skip-the-middle lint across all shifts ---------------------------------
const flagged = results.filter((r) => r.skips.length > 0);
// NOTE: this topology lint OVER-flags — in this dense, bridge-connected graph,
// driving past another truck's delivery (Factoria, Bellevue, Medina, the
// bridgeheads) is the NORMAL corridor structure, not a bug. It flags ~all shifts,
// so it can't distinguish a hole from correct routing. The cost-based optimality
// probe below is the real detector: it only fires when a move actually lowers pain.
console.log(`\n=== SKIP-THE-MIDDLE lint (${CHAINS.length} chain triplets) — topology only, OVER-flags ===`);
console.log(`  ${flagged.length}/${N} shifts thread a chain-middle held by another truck (mostly correct corridor structure — see the cost probe for real holes)`);

// --- Full detail of the single worst shift ----------------------------------
const top = worst[0];
console.log(`\n=== WORST: S${top.shift} (seed ${top.seed}) — pain ${top.pain}, time ${top.time}, ${top.deployed} trucks ===`);
console.log(`  demand: ${top.demand.map(([n, c]) => `${n} ${c}`).join("  ·  ")}`);
console.log(`  west ${top.westDemand} / east ${top.eastDemand} totes`);
for (const r of top.routes) {
  console.log(`  T${r.slot}  ${String(r.orders).padStart(2)}/${r.cap}  pain ${String(r.pain).padStart(4)}  time ${String(r.time).padStart(3)}   FC → ${r.nbhds} → FC`);
}

// --- Optimality probe on the 12 most painful shifts -------------------------
console.log(`\n=== OPTIMALITY PROBE — any pain-reducing move the solver missed? (12 worst shifts) ===`);
let anyHole = 0;
for (const r of worst) {
  // Intra-route mis-ordering: a route whose stops aren't in their cheapest order.
  const misorder = r.raw
    .map((st, slot) => ({ slot: slot + 1, gap: Math.round(painOf(sub, st) - bestPain(st)) }))
    .filter((m) => m.gap > 1);
  const moves = optimalityProbe(r.raw);
  if (moves.length === 0 && misorder.length === 0) {
    console.log(`  S${String(r.shift).padStart(3)}  pain ${r.pain}  —  locally optimal (no improving relocate/swap/reorder)`);
    continue;
  }
  anyHole++;
  const mo = misorder.map((m) => `T${m.slot} reorder −${m.gap}`).join(", ");
  const mv = moves.slice(0, 4).map((m) => `${m.detail} (−${m.saved})`).join("; ");
  console.log(`  S${String(r.shift).padStart(3)}  pain ${r.pain}  —  ${[mo, mv].filter(Boolean).join("  |  ")}`);
}
console.log(`\n  ${anyHole === 0 ? "✓ all 12 worst shifts are locally optimal — the cost is the demand, not the algorithm" : `${anyHole}/12 worst shifts have an improving move — candidate holes`}`);

// --- Optimality probe across ALL shifts (prevalence + biggest misses) --------
const allMoves = results.map((r) => ({ shift: r.shift, pain: r.pain, best: optimalityProbe(r.raw)[0] }));
const withHole = allMoves.filter((m) => m.best);
const totalSaved = withHole.reduce((s, m) => s + m.best!.saved, 0);
console.log(`\n=== OPTIMALITY PROBE — all ${N} shifts ===`);
console.log(`  ${withHole.length}/${N} shifts have ≥1 missed move; total best-move pain recoverable ≈ ${totalSaved} (~${(totalSaved / pains.reduce((s, v) => s + v, 0) * 100).toFixed(2)}% of all pain)`);
console.log(`  --- 12 biggest single missed moves ---`);
for (const m of [...withHole].sort((a, b) => b.best!.saved - a.best!.saved).slice(0, 12)) {
  console.log(`  S${String(m.shift).padStart(3)}  pain ${m.pain}  −${String(m.best!.saved).padStart(3)}  ${m.best!.kind}: ${m.best!.detail}`);
}
