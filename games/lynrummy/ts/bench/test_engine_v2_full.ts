// Run engine_v2 on ALL solve scenarios. Categorize: optimal,
// longer-than-expected, regressed (got null when expected solvable),
// invalid (plan didn't verify clean).

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
const solveScenarios = all.filter(s => s.op === "solve");

let optimal = 0, longer = 0, shorter = 0, expectedNoplan = 0;
let regressedToNull = 0, invalid = 0, foundNew = 0;
const issues: string[] = [];
const timings: { name: string; ms: number; status: string }[] = [];

// Tier the scenarios: easy (≤3-step), medium (4-5), hard (6+ or
// no_plan). Run easy + medium first; hard requires bigger budget.
const tiered = solveScenarios.map(sc => {
  const expectNoPlan = sc.expect?.no_plan === true;
  const expectedLen = sc.expect?.plan_length as number | undefined;
  const lines = sc.expect?.plan_lines as string[] | undefined;
  const len = lines !== undefined ? lines.length : (expectedLen ?? -1);
  let tier = 0;
  if (expectNoPlan) tier = 3;
  else if (len <= 3) tier = 0;
  else if (len <= 5) tier = 1;
  else if (len <= 8) tier = 2;
  else tier = 3;
  return { sc, tier };
});

const TIER = parseInt(process.env.TIER ?? "1", 10);  // run tier 0..TIER
const filtered = tiered.filter(t => t.tier <= TIER).map(t => t.sc);
process.stderr.write(`Running ${filtered.length} scenarios (tier ≤ ${TIER})\n`);

for (const sc of filtered) {
  const expectNoPlan = sc.expect?.no_plan === true;
  const expectedLines = sc.expect?.plan_lines as string[] | undefined;
  const expectedLen = sc.expect?.plan_length as number | undefined;
  const wantLen = expectedLines !== undefined ? expectedLines.length : (expectedLen ?? -1);

  const initial = classifyBuckets(buildRaw(sc));
  process.stderr.write(`  ${sc.name} ... `);
  const t0 = nowMs();
  const plan = solveTurn(initial, { maxDepth: 20 });
  const ms = nowMs() - t0;
  process.stderr.write(`${ms.toFixed(0)}ms (${plan === null ? "null" : plan.length})\n`);

  let status = "";
  if (expectNoPlan) {
    if (plan === null) {
      expectedNoplan++;
      status = "no_plan_ok";
    } else {
      foundNew++;
      const v = verifyCleanBoard(initial, plan);
      status = v.ok ? `NEW_PLAN(${plan.length})` : `INVALID: ${v.msg}`;
      if (!v.ok) invalid++;
      issues.push(`${sc.name}: was no_plan, found ${plan.length}-step (${v.ok ? "valid" : "INVALID"})`);
    }
  } else if (plan === null) {
    regressedToNull++;
    status = "REGRESSION";
    issues.push(`${sc.name}: was solvable (${wantLen} lines), got null`);
  } else {
    const v = verifyCleanBoard(initial, plan);
    if (!v.ok) {
      invalid++;
      status = `INVALID: ${v.msg}`;
      issues.push(`${sc.name}: invalid — ${v.msg}`);
    } else if (wantLen === -1) {
      optimal++;  // no length pinned; pass
      status = "ok_no_length_pinned";
    } else if (plan.length === wantLen) {
      optimal++;
      status = "optimal";
    } else if (plan.length > wantLen) {
      longer++;
      status = `+${plan.length - wantLen}`;
      issues.push(`${sc.name}: longer (want ${wantLen}, got ${plan.length})`);
    } else {
      shorter++;
      status = `-${wantLen - plan.length}`;
      issues.push(`${sc.name}: SHORTER (want ${wantLen}, got ${plan.length})`);
    }
  }
  timings.push({ name: sc.name, ms, status });
}

console.log(`\n=== engine_v2 full solve conformance ===`);
console.log(`total scenarios:     ${solveScenarios.length}`);
console.log(`optimal:             ${optimal}`);
console.log(`longer:              ${longer}`);
console.log(`shorter:             ${shorter}`);
console.log(`expected no_plan ✓:  ${expectedNoplan}`);
console.log(`new plans found:     ${foundNew}`);
console.log(`regressed to null:   ${regressedToNull}`);
console.log(`invalid plans:       ${invalid}`);
console.log(`\ntotal time: ${timings.reduce((a, t) => a + t.ms, 0).toFixed(0)}ms`);

if (issues.length > 0) {
  console.log(`\n--- Issues (${issues.length}) ---`);
  for (const i of issues.slice(0, 50)) console.log(`  ${i}`);
  if (issues.length > 50) console.log(`  ... and ${issues.length - 50} more`);
}

console.log(`\n--- Top 10 slowest ---`);
timings.sort((a, b) => b.ms - a.ms);
for (const t of timings.slice(0, 10)) {
  console.log(`  ${t.name.padEnd(40)} ${t.ms.toFixed(1).padStart(8)}ms  ${t.status}`);
}
