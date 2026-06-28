// painreg.ts — dev analysis. Sweep the first N shifts (the seed chain the UI walks
// from seed 49) and fit a LINEAR REGRESSION of each day's total fleet PAIN against
// its per-neighborhood home counts. The point is to separate "expensive" from
// "pathological":
//
//   - The coefficients are each neighborhood's marginal pain-per-home — its
//     inherent cost to the WHOLE network (West Seattle homes are dear; near-FC
//     homes are cheap). This is a network effect, not a single house's local cost.
//   - The RESIDUAL (actual − predicted) is the day's SYNERGY: how much more (or
//     less) painful it is than its neighborhood mix alone predicts. A west-heavy
//     day is predicted painful, so its residual is small — a red herring we can now
//     ignore. A day whose residual is large+positive is genuinely pathological:
//     the cost isn't explained by the demand mix, so something structural is wrong.
//
// No intercept: every shift delivers exactly FLEET.orders homes, so the counts sum
// to a constant — they already span the constant, and an explicit intercept would
// make X'X singular. Each coefficient is then a clean pain-per-home. N=20-ish
// features, 500 rows: the fit is O(N·rows) to assemble + O(N^3) to solve, trivial.
//
//   delivery/node_modules/.bin/esbuild delivery/painreg.ts \
//     --bundle --platform=node --format=esm --outfile=/tmp/pr.mjs && node /tmp/pr.mjs

import { buildSubstrate } from "./roadgraph.ts";
import { solve, painOf } from "./solver.ts";
import { chooseOrders, ordersByNeighborhood, demandByNeighborhood } from "./orders.ts";
import { FLEET, NEIGHBORHOODS } from "./geography.ts";

const N = 500;
const sub = buildSubstrate();

// Feature columns: every neighborhood that can receive orders (houses > 0), in a
// stable order. (Mercer Island has 0 houses → always-zero column, dropped.)
const COLS = NEIGHBORHOODS.filter((n) => n.houses > 0).map((n) => n.name);
const COL = new Map(COLS.map((name, i) => [name, i]));
const K = COLS.length;

// The same LCG the UI walks shift to shift (main.ts).
function shiftSeeds(n: number): number[] {
  const seeds: number[] = [];
  let seed = 49;
  for (let i = 0; i < n; i++) {
    seeds.push(seed);
    seed = (seed * 1664525 + 1013904223) >>> 0;
  }
  return seeds;
}

// Assemble the design matrix X (per-neighborhood home counts) and target y (pain).
const seeds = shiftSeeds(N);
const X: number[][] = [];
const y: number[] = [];
for (const seed of seeds) {
  const orders = chooseOrders(seed, FLEET.orders);
  const row = new Array(K).fill(0);
  for (const [nbhd, count] of demandByNeighborhood(orders)) {
    const c = COL.get(nbhd);
    if (c !== undefined) row[c] = count;
  }
  const plan = solve(sub, ordersByNeighborhood(orders));
  X.push(row);
  y.push(plan.routes.reduce((s, r) => s + painOf(sub, r.stops), 0));
}

// Normal equations: (XᵀX) β = Xᵀy. K×K, solved by Gaussian elimination w/ pivoting.
const A: number[][] = Array.from({ length: K }, () => new Array(K).fill(0));
const b: number[] = new Array(K).fill(0);
for (let r = 0; r < N; r++) {
  const xr = X[r];
  for (let j = 0; j < K; j++) {
    if (xr[j] === 0) continue;
    b[j] += xr[j] * y[r];
    for (let k = j; k < K; k++) A[j][k] += xr[j] * xr[k];
  }
}
for (let j = 0; j < K; j++) for (let k = 0; k < j; k++) A[j][k] = A[k][j]; // symmetric fill

function solveLinear(M: number[][], rhs: number[]): number[] {
  const n = rhs.length;
  const a = M.map((row, i) => [...row, rhs[i]]); // augmented
  for (let col = 0; col < n; col++) {
    let piv = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(a[r][col]) > Math.abs(a[piv][col])) piv = r;
    [a[col], a[piv]] = [a[piv], a[col]];
    const d = a[col][col];
    for (let k = col; k <= n; k++) a[col][k] /= d;
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = a[r][col];
      if (f === 0) continue;
      for (let k = col; k <= n; k++) a[r][k] -= f * a[col][k];
    }
  }
  return a.map((row) => row[n]);
}

const beta = solveLinear(A, b);

// Predictions, residuals, and fit quality.
const pred = X.map((xr) => xr.reduce((s, v, j) => s + v * beta[j], 0));
const resid = y.map((v, i) => v - pred[i]);
const meanY = y.reduce((s, v) => s + v, 0) / N;
const ssRes = resid.reduce((s, e) => s + e * e, 0);
const ssTot = y.reduce((s, v) => s + (v - meanY) ** 2, 0);
const r2 = 1 - ssRes / ssTot; // counts sum to a constant ⇒ centered R² is meaningful
const rmse = Math.sqrt(ssRes / N);
const meanCount = COLS.map((_, j) => X.reduce((s, xr) => s + xr[j], 0) / N);

console.log(`=== PAIN REGRESSION — ${N} shifts, total fleet pain ~ per-neighborhood home counts (no intercept) ===`);
console.log(`  mean pain ${meanY.toFixed(0)}   R² ${r2.toFixed(4)}   RMSE ${rmse.toFixed(1)} pain   (≈ ${(100 * rmse / meanY).toFixed(1)}% of mean)\n`);

console.log("  pain/home by neighborhood (the inherent network cost of a home there):");
console.log("    neighborhood        pain/home   avg homes/day   avg pain share");
const order = COLS.map((_, j) => j).sort((p, q) => beta[q] - beta[p]);
for (const j of order) {
  const share = beta[j] * meanCount[j];
  console.log(
    `    ${COLS[j].padEnd(16)} ${beta[j].toFixed(1).padStart(8)}   ${meanCount[j].toFixed(2).padStart(10)}   ${share.toFixed(0).padStart(10)}`,
  );
}

// Synergy ranking: residual standardized by RMSE → a z-score of "how much more
// painful than its mix predicts". Positive = pathological; negative = good synergy.
const ranked = resid
  .map((e, i) => ({ shift: i + 1, actual: y[i], pred: pred[i], resid: e, z: e / rmse }))
  .sort((p, q) => q.resid - p.resid);

console.log("\n=== MOST PATHOLOGICAL (actual ≫ predicted — bad synergy, NOT just west-heavy) ===");
console.log("    shift   actual   predicted   residual    z");
for (const s of ranked.slice(0, 15))
  console.log(
    `    S${String(s.shift).padEnd(4)}  ${s.actual.toFixed(0).padStart(6)}   ${s.pred.toFixed(0).padStart(9)}   ${s.resid.toFixed(0).padStart(8)}   ${s.z.toFixed(2).padStart(5)}`,
  );

console.log("\n=== BEST SYNERGY (actual ≪ predicted — the mix routes better than its parts) ===");
console.log("    shift   actual   predicted   residual    z");
for (const s of ranked.slice(-5).reverse())
  console.log(
    `    S${String(s.shift).padEnd(4)}  ${s.actual.toFixed(0).padStart(6)}   ${s.pred.toFixed(0).padStart(9)}   ${s.resid.toFixed(0).padStart(8)}   ${s.z.toFixed(2).padStart(5)}`,
  );

// For contrast: the raw-pain ranking (the old red-herring view) and where those land on synergy.
const byPain = resid.map((e, i) => ({ shift: i + 1, actual: y[i], resid: e, z: e / rmse })).sort((p, q) => q.actual - p.actual);
console.log("\n=== for contrast: TOP 8 by RAW PAIN (old view) — note their synergy z ===");
console.log("    shift   actual   residual    z");
for (const s of byPain.slice(0, 8))
  console.log(`    S${String(s.shift).padEnd(4)}  ${s.actual.toFixed(0).padStart(6)}   ${s.resid.toFixed(0).padStart(8)}   ${s.z.toFixed(2).padStart(5)}`);
