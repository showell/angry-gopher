// Run perf_curated under three singleton-doom modes (off/low/high).

import * as fs from "node:fs";
import * as path from "node:path";

import { solveStateWithDescs } from "../src/bfs.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { setSingletonDoomMode, type SingletonDoomMode } from "../src/enumerator.ts";
import { type Card } from "../src/rules/card.ts";

interface BoardCard { card: { value: number; suit: number; origin_deck: number } }
interface BoardStack { board_cards: BoardCard[] }
interface Scenario {
  name: string; op: string;
  helper?: BoardStack[]; trouble?: BoardStack[]; growing?: BoardStack[]; complete?: BoardStack[];
  expect: Record<string, unknown>;
}

const FIXTURES = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../python/conformance_fixtures.json");

const TARGETS = [
  "baseline_board_5C", "baseline_board_5Cp",
  "baseline_board_4D", "baseline_board_4Dp",
  "baseline_board_2Sp", "baseline_board_2Cp",
  "baseline_board_3Hp", "baseline_board_QDp",
  "baseline_board_2D", "baseline_board_2Dp", "baseline_board_3C",
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
function maybeGc() { const g = (globalThis as { gc?: () => void }).gc; if (typeof g === "function") g(); }
function nowMs() { const [s, ns] = process.hrtime(); return s * 1000 + ns / 1e6; }

const all: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES, "utf8"));

function timeIt(buckets: import("../src/buckets.ts").Buckets, n = 5): { ms: number; result: string } {
  let plan = solveStateWithDescs(buckets, { maxTroubleOuter: 12, maxStates: 500000 });
  let best = Infinity;
  for (let i = 0; i < n; i++) {
    maybeGc();
    const t0 = nowMs();
    plan = solveStateWithDescs(buckets, { maxTroubleOuter: 12, maxStates: 500000 });
    const e = nowMs() - t0;
    if (e < best) best = e;
  }
  return { ms: best, result: plan === null ? "no_plan" : `${plan.length}-step` };
}

for (const mode of ["off", "low", "high"] as SingletonDoomMode[]) {
  setSingletonDoomMode(mode);
  console.log(`\n=== singleton doom mode: ${mode} ===`);
  console.log(`${"scenario".padEnd(28)} ${"ms".padStart(9)}  result`);
  for (const name of TARGETS) {
    const sc = all.find(s => s.name === name);
    if (!sc) continue;
    const buckets = classifyBuckets(buildRaw(sc));
    const { ms, result } = timeIt(buckets);
    console.log(`${name.padEnd(28)} ${ms.toFixed(1).padStart(7)}ms  ${result}`);
  }
}
