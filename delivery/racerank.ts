// racerank.ts — dev analysis. Rank the 8 race variants over the first N shifts
// (the same seed=49 chain the UI walks) and score every PRUNE option by the pain it
// would cost. The naive signal — a variant's count of *sole* wins — is a trap: two
// variants can tie for a win that no other reaches, so neither is "unique" yet the
// pair is load-bearing. The honest test is subtractive: remove a set of variants,
// re-take the per-shift min over the survivors, and sum the regressions vs the full
// 8-way race. Deterministic; run with:
//
//   delivery/node_modules/.bin/esbuild delivery/racerank.ts \
//     --bundle --platform=node --format=esm --outfile=/tmp/rr.mjs && node /tmp/rr.mjs
//
// Optional: pass a shift count as argv[2] (default 20).

import { buildSubstrate } from "./roadgraph.ts";
import { RACE, runSolve, planPain } from "./solver.ts";
import { chooseOrders, ordersByNeighborhood } from "./orders.ts";
import { FLEET } from "./geography.ts";

declare const process: { argv: string[] }; // node-only dev script; tsconfig has no @types/node
const sub = buildSubstrate();
const N = Number(process.argv[2] ?? 20);

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

// Solve every variant per shift, timed individually, so prune options are scored from
// the same matrix and we know each variant's REAL cost (arc variants make more units →
// they're the expensive ones, which decides speed-per-pain between equal-pain prunes).
const seeds = shiftSeeds(N);
const LABELS: string[] = RACE.map((v) => v.label);
const matrix: number[][] = []; // matrix[shift][variantIdx] = pain
const variantMs: number[] = RACE.map(() => 0); // total ms per variant across the corpus

const t0 = Date.now();
for (const seed of seeds) {
  const orders = ordersByNeighborhood(chooseOrders(seed, FLEET.orders));
  const row: number[] = [];
  for (let k = 0; k < RACE.length; k++) {
    const v = RACE[k];
    const tv = Date.now();
    const plan = runSolve(sub, orders, true, v.costAware, v.defer, v.arcSplit);
    variantMs[k] += Date.now() - tv;
    row.push(planPain(sub, plan));
  }
  matrix.push(row);
}
const elapsed = Date.now() - t0;

const fullBest = matrix.map((row) => Math.min(...row));

// Score a survivor set (indices): shifts regressed + total pain added vs full race.
function scoreSurvivors(keep: number[]): { regressed: number[]; added: number } {
  const regressed: number[] = [];
  let added = 0;
  for (let s = 0; s < N; s++) {
    const sub = Math.min(...keep.map((k) => matrix[s][k]));
    if (sub > fullBest[s]) {
      regressed.push(s + 1);
      added += sub - fullBest[s];
    }
  }
  return { regressed, added };
}

const idx = (pred: (l: string) => boolean) => LABELS.map((l, i) => [l, i] as const).filter(([l]) => pred(l)).map(([, i]) => i);
const all = LABELS.map((_, i) => i);

// ---- per-variant ranking ----
type Stat = { label: string; wins: number; unique: number; sumRegret: number; maxRegret: number };
const stats: Stat[] = LABELS.map((label, k) => {
  let wins = 0, unique = 0, sumRegret = 0, maxRegret = 0;
  for (let s = 0; s < N; s++) {
    const regret = matrix[s][k] - fullBest[s];
    sumRegret += regret;
    maxRegret = Math.max(maxRegret, regret);
    if (matrix[s][k] === fullBest[s]) {
      wins++;
      if (matrix[s].filter((p) => p === fullBest[s]).length === 1) unique++;
    }
  }
  return { label, wins, unique, sumRegret, maxRegret };
});

const msOf = (label: string) => variantMs[LABELS.indexOf(label)];
console.log(`\n=== RACE VARIANT RANKING over ${N} shifts (S1..S${N}) ===`);
console.log(`total: ${elapsed}ms  (${(elapsed / N).toFixed(0)}ms/shift, full 8-way race)\n`);
console.log("variant".padEnd(14), "unique".padStart(7), "wins".padStart(6), "avgRegret".padStart(11), "maxRegret".padStart(10), "ms/shift".padStart(9));
for (const s of [...stats].sort((a, b) => b.unique - a.unique || b.wins - a.wins || a.sumRegret - b.sumRegret))
  console.log(s.label.padEnd(14), String(s.unique).padStart(7), `${s.wins}/${N}`.padStart(6), (s.sumRegret / N).toFixed(2).padStart(11), String(s.maxRegret).padStart(10), (msOf(s.label) / N).toFixed(0).padStart(9));

// ---- prune menu: subtractive, the honest test ----
console.log(`\n=== PRUNE MENU (subtractive — remove a set, re-min over survivors) ===`);
const report = (name: string, keep: number[]) => {
  const { regressed, added } = scoreSurvivors(keep);
  const keptMs = keep.reduce((m, k) => m + variantMs[k], 0) / N; // REAL survivor cost, not a uniform estimate
  const speed = `${keep.length}-way (${keptMs.toFixed(0)}ms/shift, ${(keptMs / (elapsed / N) * 100).toFixed(0)}% of full)`;
  const cost = regressed.length === 0 ? "FREE — 0 shifts regress" : `${regressed.length} shift(s) +${added} total (avg +${(added / N).toFixed(1)}/shift); worst S${regressed.join(",S")}`;
  console.log(`  ${name.padEnd(24)} ${speed.padEnd(34)} ${cost}`);
};

console.log("\n-- drop one variant (7-way):");
for (let k = 0; k < LABELS.length; k++) report(`-${LABELS[k]}`, all.filter((i) => i !== k));

console.log("\n-- collapse an axis (4-way):");
report("arc→whole", idx((l) => l.includes("/whole/")));
report("arc→arc", idx((l) => l.includes("/arc/")));
report("medina→M+", idx((l) => l.endsWith("/M+")));
report("medina→M-", idx((l) => l.endsWith("/M-")));
report("split→room", idx((l) => l.startsWith("room/")));
report("split→cost", idx((l) => l.startsWith("cost/")));
console.log();
