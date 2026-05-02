// bench_2sp.ts — TROUBLE_HANDS focal case: 2Sp on the Game 17 board.
//
// 2Sp is the slowest no_plan in the 81-card baseline (~127ms in the
// gold). This driver pins it as a single-purpose perf gauge: 10 timed
// runs (after one warmup), report min/median/max/mean wall, plus the
// cap-exhaustion record so each optimization round can read what
// happened inside the search.
//
// Use as the gold for "did this change make 2Sp faster?" — re-run
// before and after each optimization.
//
// Usage:
//   node --expose-gc bench/bench_2sp.ts

import { solveStateWithDescsExt, type CapExhaustion } from "../src/bfs.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

// Game 17 board — same fixture as gen_baseline_board.ts.
const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

// 2Sp = 2 of Spades, deck-1.
const TROUBLE: Card = [2, SUITS.indexOf("S"), 1] as const;

const N_RUNS = 10;
const MAX_STATES = 200000;
const MAX_TROUBLE_OUTER = 10;

function parseLabel(label: string): Card {
  const rankIdx = RANKS.indexOf(label[0]!);
  const suitIdx = SUITS.indexOf(label[1]!);
  if (rankIdx < 0 || suitIdx < 0) throw new Error(`bad label ${label}`);
  return [rankIdx + 1, suitIdx, 0] as const;
}

function maybeGc(): void {
  const g = (globalThis as { gc?: () => void }).gc;
  if (typeof g === "function") g();
}

function nowMs(): number {
  const [s, ns] = process.hrtime();
  return s * 1000 + ns / 1e6;
}

function fmt(ms: number): string {
  return ms.toFixed(2).padStart(7);
}

function median(xs: readonly number[]): number {
  const sorted = [...xs].sort((a, b) => a - b);
  const n = sorted.length;
  if (n === 0) return 0;
  const mid = Math.floor(n / 2);
  return n % 2 === 1 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

function mean(xs: readonly number[]): number {
  if (xs.length === 0) return 0;
  return xs.reduce((a, b) => a + b, 0) / xs.length;
}

function summarizeExhaustions(exh: readonly CapExhaustion[]): string {
  if (exh.length === 0) return "  (none — search found a plan or pruned to empty)";
  const lines: string[] = [];
  for (const e of exh) {
    const tag = e.hitMaxStates ? "HIT_MAX_STATES" : "natural";
    lines.push(
      `  cap=${String(e.cap).padStart(2)}  expansions=${String(e.expansions).padStart(6)}` +
      `  seen=${String(e.seenCount).padStart(6)}  ${tag}`
    );
  }
  return lines.join("\n");
}

function main(): void {
  const helper = BOARD_LABELS.map(stack => stack.map(parseLabel));
  const raw: RawBuckets = {
    helper,
    trouble: [[TROUBLE]],
    growing: [],
    complete: [],
  };
  const buckets = classifyBuckets(raw);

  console.log(`bench_2sp — Game 17 board + trouble=[2Sp]`);
  console.log(`config: N_RUNS=${N_RUNS}  maxStates=${MAX_STATES}  maxTroubleOuter=${MAX_TROUBLE_OUTER}`);
  console.log("");

  // Warmup (untimed).
  const warm = solveStateWithDescsExt(buckets, {
    maxTroubleOuter: MAX_TROUBLE_OUTER,
    maxStates: MAX_STATES,
  });
  console.log(`warmup: plan=${warm.plan === null ? "no_plan" : warm.plan.length + "-step"}  exhaustions=${warm.exhaustions.length}`);

  // Timed runs.
  const samples: number[] = [];
  let lastResult: { plan: ReturnType<typeof solveStateWithDescsExt>["plan"]; exhaustions: readonly CapExhaustion[] } = warm;
  for (let i = 0; i < N_RUNS; i++) {
    maybeGc();
    const t0 = nowMs();
    const r = solveStateWithDescsExt(buckets, {
      maxTroubleOuter: MAX_TROUBLE_OUTER,
      maxStates: MAX_STATES,
    });
    const ms = nowMs() - t0;
    samples.push(ms);
    lastResult = r;
  }

  console.log("");
  console.log(`per-run wall (ms):`);
  for (let i = 0; i < samples.length; i++) {
    console.log(`  run ${String(i + 1).padStart(2)}  ${fmt(samples[i]!)}`);
  }
  console.log("");
  console.log(`min    = ${fmt(Math.min(...samples))} ms`);
  console.log(`median = ${fmt(median(samples))} ms`);
  console.log(`mean   = ${fmt(mean(samples))} ms`);
  console.log(`max    = ${fmt(Math.max(...samples))} ms`);
  console.log("");
  console.log(`result: ${lastResult.plan === null ? "no_plan" : lastResult.plan.length + "-step"}`);
  console.log(`exhaustions (${lastResult.exhaustions.length}):`);
  console.log(summarizeExhaustions(lastResult.exhaustions));
}

main();
