// Run engine_v2 on the 46 easy (plan-length<=3) scenarios.
// For each: report timing, result, and whether the plan verifies clean.

import * as fs from "node:fs";
import * as path from "node:path";

import { solveTurn } from "../src/engine_v2.ts";
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
const easy = all.filter(s => {
  if (s.op !== "solve") return false;
  const len = (s.expect?.plan_length as number | undefined) ?? (s.expect?.plan_lines as string[] | undefined)?.length;
  return len !== undefined && len <= 3;
});

console.log(`Running engine_v2 on ${easy.length} easy scenarios:\n`);
console.log(`${"scenario".padEnd(40)} ${"want".padStart(5)} ${"got".padStart(5)} ${"ms".padStart(8)}  status`);

let passed = 0, failed = 0, regressed = 0;
const failures: string[] = [];
for (const sc of easy) {
  process.stdout.write(`${sc.name.padEnd(40)} `);
  const want = (sc.expect?.plan_length as number | undefined) ?? (sc.expect?.plan_lines as string[] | undefined)?.length ?? 0;
  const initial = classifyBuckets(buildRaw(sc));

  const t0 = nowMs();
  // Lower depth cap to bound any per-scenario runaway.
  const plan = solveTurn(initial, { maxDepth: 12 });
  const ms = nowMs() - t0;

  let status = "";
  if (plan === null) {
    status = "REGRESSION (got null)";
    regressed++;
    failures.push(sc.name);
  } else {
    const verify = verifyCleanBoard(initial, plan);
    if (!verify.ok) { status = `INVALID: ${verify.msg}`; failed++; failures.push(sc.name); }
    else { status = "OK"; passed++; }
  }
  const got = plan === null ? "-" : plan.length.toString();
  console.log(`${String(want).padStart(5)} ${got.padStart(5)} ${ms.toFixed(1).padStart(7)}ms  ${status}`);
}

console.log(`\n=== Summary ===`);
console.log(`passed:     ${passed}`);
console.log(`failed:     ${failed} (invalid plan)`);
console.log(`regressed:  ${regressed} (returned null)`);
if (failures.length > 0) {
  console.log(`\nFailures: ${failures.join(", ")}`);
}
