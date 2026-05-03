// bench_5c.ts — focal case for decompose perf analysis.
//
// Game 17 board + trouble [5C]. Was 1.1ms in baseline gold (no_plan),
// jumped to ~572ms with decompose enabled. Simplest state with the
// largest perf ratio — best case to measure no-reunion guard against.

import { solveStateWithDescsExt, type CapExhaustion } from "../src/bfs.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];
const TROUBLE: Card = [5, SUITS.indexOf("C"), 0] as const;

const N_RUNS = 10;
const MAX_STATES = 500000;
const MAX_TROUBLE_OUTER = 12;

function parseLabel(label: string): Card {
  const r = RANKS.indexOf(label[0]!);
  const s = SUITS.indexOf(label[1]!);
  return [r + 1, s, 0] as const;
}

function maybeGc(): void {
  const g = (globalThis as { gc?: () => void }).gc;
  if (typeof g === "function") g();
}
function nowMs(): number { const [s, ns] = process.hrtime(); return s * 1000 + ns / 1e6; }
function fmt(n: number): string { return n.toFixed(2).padStart(7); }
function median(xs: readonly number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}

function main(): void {
  const helper = BOARD_LABELS.map(stk => stk.map(parseLabel));
  const raw: RawBuckets = { helper, trouble: [[TROUBLE]], growing: [], complete: [] };
  const buckets = classifyBuckets(raw);

  console.log(`bench_5c — Game 17 board + trouble [5C]`);
  console.log(`config: N_RUNS=${N_RUNS}  maxStates=${MAX_STATES}  maxTroubleOuter=${MAX_TROUBLE_OUTER}`);

  const warm = solveStateWithDescsExt(buckets, { maxTroubleOuter: MAX_TROUBLE_OUTER, maxStates: MAX_STATES });
  console.log(`\nwarmup: ${warm.plan === null ? "no_plan" : warm.plan.length + "-step"}  exhaustions=${warm.exhaustions.length}`);

  const samples: number[] = [];
  let last: { plan: typeof warm.plan; exhaustions: readonly CapExhaustion[] } = warm;
  for (let i = 0; i < N_RUNS; i++) {
    maybeGc();
    const t0 = nowMs();
    const r = solveStateWithDescsExt(buckets, { maxTroubleOuter: MAX_TROUBLE_OUTER, maxStates: MAX_STATES });
    samples.push(nowMs() - t0);
    last = r;
  }

  console.log(`\nper-run wall (ms):`);
  for (let i = 0; i < samples.length; i++) console.log(`  run ${String(i + 1).padStart(2)}  ${fmt(samples[i]!)}`);
  console.log(`\nmin    = ${fmt(Math.min(...samples))} ms`);
  console.log(`median = ${fmt(median(samples))} ms`);
  console.log(`max    = ${fmt(Math.max(...samples))} ms`);
  console.log(`\nresult: ${last.plan === null ? "no_plan" : last.plan.length + "-step"}`);
  console.log(`exhaustions:`);
  for (const e of last.exhaustions) {
    console.log(`  cap=${String(e.cap).padStart(2)}  expansions=${String(e.expansions).padStart(7)}  seen=${String(e.seenCount).padStart(7)}  ${e.hitMaxStates ? "HIT_MAX" : "natural"}`);
  }
}

main();
