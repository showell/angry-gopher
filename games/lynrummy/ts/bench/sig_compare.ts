// Compare string-sig vs fast-sig for dedup. Visit count should
// match (same dedup decisions); wall time difference shows the
// representation cost.

import * as fs from "node:fs";
import * as path from "node:path";

import { solveTurn, lastVisits } from "../src/engine_v2.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { type Card } from "../src/rules/card.ts";

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
const targets = ["corpus_sid_130","corpus_sid_116","corpus_sid_110","corpus_sid_146","mined_mined_006_2Cp1","corpus_sid_122","corpus_sid_114","corpus_sid_118","mined_mined_001_2Hp1","mined_mined_004_6H"];

console.log(`${"scenario".padEnd(28)} ${"len".padStart(4)}  ${"string-sig".padStart(18)}  ${"fast-sig".padStart(18)}  ${"speedup".padStart(8)}`);
console.log("-".repeat(86));

let totalString = 0, totalFast = 0;
for (const name of targets) {
  const sc = all.find(s => s.name === name);
  if (!sc) continue;
  const initial = classifyBuckets(buildRaw(sc));

  // Warmup
  solveTurn(initial, { budget: 50000, sigKind: "string" });
  solveTurn(initial, { budget: 50000, sigKind: "fast" });

  // Best of 3 for each
  const runOnce = (kind: "string" | "fast") => {
    let bestMs = Infinity;
    let visits = 0, planLen = 0;
    for (let i = 0; i < 3; i++) {
      const t0 = nowMs();
      const plan = solveTurn(initial, { budget: 50000, sigKind: kind });
      const ms = nowMs() - t0;
      if (ms < bestMs) bestMs = ms;
      visits = lastVisits;
      planLen = plan?.length ?? 0;
    }
    return { ms: bestMs, visits, planLen };
  };

  const a = runOnce("string");
  const b = runOnce("fast");
  if (a.visits !== b.visits) {
    console.log(`${name}: VISIT COUNT DIVERGES (string=${a.visits}, fast=${b.visits})`);
    continue;
  }
  totalString += a.ms;
  totalFast += b.ms;
  const speedup = (a.ms / b.ms).toFixed(2) + "x";
  console.log(
    `${name.padEnd(28)} ${String(a.planLen).padStart(4)}  ${(a.visits + " (" + a.ms.toFixed(0) + "ms)").padStart(18)}  ${(b.visits + " (" + b.ms.toFixed(0) + "ms)").padStart(18)}  ${speedup.padStart(8)}`,
  );
}
console.log("-".repeat(86));
console.log(`Total ms (best-of-3, summed): string=${totalString.toFixed(0)}ms, fast=${totalFast.toFixed(0)}ms, speedup=${(totalString/totalFast).toFixed(2)}x`);
