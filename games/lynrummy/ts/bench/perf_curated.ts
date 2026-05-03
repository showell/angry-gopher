// perf_curated.ts — time a small curated set of baseline_board_81
// scenarios under whatever solver config is current. Focus on the
// cases that regressed when decompose was first added (most diagnostic
// for bucket-gating's effect).

import * as fs from "node:fs";
import * as path from "node:path";

import { solveStateWithDescs } from "../src/bfs.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { type Card } from "../src/rules/card.ts";

interface BoardCard { card: { value: number; suit: number; origin_deck: number } }
interface BoardStack { board_cards: BoardCard[] }
interface Scenario {
  name: string;
  op: string;
  helper?: BoardStack[];
  trouble?: BoardStack[];
  growing?: BoardStack[];
  complete?: BoardStack[];
  expect: Record<string, unknown>;
}

const FIXTURES = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../python/conformance_fixtures.json",
);

// Worst regressions when decompose was first turned on (no bucket gating):
//   5C, 5Cp:    1ms → 572ms (520x)
//   4D, 4Dp:    1ms → 212ms (180x)
//   2Sp, 2Cp:   the original TROUBLE_HANDS focal cases
//   3Hp:        31ms → 756ms (24x)
//   QDp:        9ms  → 352ms (40x)
//
// Plus controls (should stay fast):
//   2D, 2Dp:    1ms (always solved)
//   3C:         (was 0.6ms, 4-step)
const TARGETS = [
  // Regressed cases:
  "baseline_board_5C", "baseline_board_5Cp",
  "baseline_board_4D", "baseline_board_4Dp",
  "baseline_board_2Sp", "baseline_board_2Cp",
  "baseline_board_3Hp", "baseline_board_QDp",
  // Controls:
  "baseline_board_2D", "baseline_board_2Dp",
  "baseline_board_3C",
];

function bucketToTuples(stacks: BoardStack[] | undefined): Card[][] {
  if (!stacks) return [];
  return stacks.map(s => s.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as const));
}
function buildRaw(sc: Scenario): RawBuckets {
  return {
    helper: bucketToTuples(sc.helper),
    trouble: bucketToTuples(sc.trouble),
    growing: bucketToTuples(sc.growing),
    complete: bucketToTuples(sc.complete),
  };
}

function maybeGc(): void {
  const g = (globalThis as { gc?: () => void }).gc;
  if (typeof g === "function") g();
}
function nowMs(): number {
  const [s, ns] = process.hrtime();
  return s * 1000 + ns / 1e6;
}

function timeIt(buckets: import("../src/buckets.ts").Buckets, n = 5): { ms: number; result: string } {
  // warmup
  let plan = solveStateWithDescs(buckets, { maxTroubleOuter: 12, maxStates: 500000 });
  let best = Infinity;
  for (let i = 0; i < n; i++) {
    maybeGc();
    const t0 = nowMs();
    plan = solveStateWithDescs(buckets, { maxTroubleOuter: 12, maxStates: 500000 });
    const e = nowMs() - t0;
    if (e < best) best = e;
  }
  return {
    ms: best,
    result: plan === null ? "no_plan" : `${plan.length}-step`,
  };
}

const all: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES, "utf8"));

// Old gold times (before decompose) for reference.
const oldGold: Record<string, number> = {
  "baseline_board_5C": 1.1,
  "baseline_board_5Cp": 1.1,
  "baseline_board_4D": 1.2,
  "baseline_board_4Dp": 1.2,
  "baseline_board_2Sp": 126.7,
  "baseline_board_2Cp": 104.5,
  "baseline_board_3Hp": 31.3,
  "baseline_board_QDp": 8.8,
  "baseline_board_2D": 0.5,
  "baseline_board_2Dp": 0.5,
  "baseline_board_3C": 0.6,
};

console.log("Curated perf check (current config: shift+decompose, bucket-gated)");
console.log(`${"scenario".padEnd(28)} ${"old".padStart(8)} ${"new".padStart(8)} ${"ratio".padStart(7)}  result`);
for (const name of TARGETS) {
  const sc = all.find(s => s.name === name);
  if (!sc) { console.log(`${name}: NOT FOUND`); continue; }
  const buckets = classifyBuckets(buildRaw(sc));
  const { ms, result } = timeIt(buckets);
  const old = oldGold[name];
  const ratio = old !== undefined ? `${(ms / old).toFixed(1)}x` : "-";
  console.log(
    `${name.padEnd(28)} ${(old ?? 0).toFixed(1).padStart(7)}ms ${ms.toFixed(1).padStart(7)}ms ${ratio.padStart(7)}  ${result}`,
  );
}
