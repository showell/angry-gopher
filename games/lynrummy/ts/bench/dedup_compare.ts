// Compare A* with and without state-sig dedup. Visit count is the
// noise-free metric; wall time shown for context.

import * as fs from "node:fs";
import * as path from "node:path";

import { solveTurn, lastVisits } from "../src/engine_v2.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { type Card } from "../src/rules/card.ts";
import { verifyCleanBoard } from "./verify_clean_board.ts";

interface BoardCard { card: { value: number; suit: number; origin_deck: number } }
interface BoardStack { board_cards: BoardCard[] }
interface Scenario {
  name: string; op: string;
  helper?: BoardStack[]; trouble?: BoardStack[]; growing?: BoardStack[]; complete?: BoardStack[];
  expect: Record<string, unknown>;
}

const FIXTURES = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../python/conformance_fixtures.json");
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
function nowMs() { const [s, ns] = process.hrtime(); return s * 1000 + ns / 1e6; }

const all: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES, "utf8"));
const targets = ["corpus_sid_130","corpus_sid_116","corpus_sid_110","corpus_sid_146","mined_mined_006_2Cp1","corpus_sid_122","corpus_sid_114","corpus_sid_118","mined_mined_001_2Hp1","mined_mined_004_6H","corpus_sid_138","corpus_sid_112"];

console.log(`${"scenario".padEnd(28)} ${"len".padStart(4)} ${"NO_DEDUP visits".padStart(20)} ${"DEDUP visits".padStart(20)} ${"reduction".padStart(11)}`);
console.log("-".repeat(90));

let totalNoDedup = 0, totalDedup = 0;
for (const name of targets) {
  const sc = all.find(s => s.name === name);
  if (!sc) continue;
  const initial = classifyBuckets(buildRaw(sc));

  // No dedup
  const t0a = nowMs();
  const planA = solveTurn(initial, { budget: 50000, dedup: false });
  const msA = nowMs() - t0a;
  const visitsNoDedup = lastVisits;

  // Dedup
  const t0b = nowMs();
  const planB = solveTurn(initial, { budget: 50000, dedup: true });
  const msB = nowMs() - t0b;
  const visitsDedup = lastVisits;

  if (planA === null || planB === null) { console.log(`${name}: stuck`); continue; }
  if (planA.length !== planB.length) { console.log(`${name}: PLAN-LEN DIVERGES (no_dedup=${planA.length}, dedup=${planB.length})`); continue; }

  totalNoDedup += visitsNoDedup;
  totalDedup += visitsDedup;
  const reduction = ((1 - visitsDedup / visitsNoDedup) * 100).toFixed(1) + "%";
  console.log(
    `${name.padEnd(28)} ${String(planA.length).padStart(4)} ` +
    `${(visitsNoDedup + " (" + msA.toFixed(0) + "ms)").padStart(20)} ` +
    `${(visitsDedup + " (" + msB.toFixed(0) + "ms)").padStart(20)} ` +
    `${reduction.padStart(11)}`
  );
}
console.log("-".repeat(90));
console.log(`Total visits: no_dedup=${totalNoDedup}, dedup=${totalDedup}, reduction=${((1 - totalDedup / totalNoDedup) * 100).toFixed(1)}%`);
