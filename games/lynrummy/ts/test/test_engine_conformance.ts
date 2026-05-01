// test_engine_conformance.ts — TS scenario-level conformance runner.
//
// Reads `python/conformance_fixtures.json` (the same JSON the Python
// `test_dsl_conformance.py` consumes) and runs the TS engine against
// the `enumerate_moves` and `solve` ops for at least the v1 surface:
//
//   - All `enumerate_moves` scenarios — assert the matching `yields`
//     type (or `narrate_contains` / `hint_contains` substring) is
//     produced by the TS engine.
//   - A hand-picked subset of `solve` scenarios — assert plan length
//     OR plan lines (when the scenario provides them) match Python.
//
// Other ops (build_suggestions, hint_invariant, find_open_loc,
// hint_for_hand) are reported as SKIP — they live above the BFS layer
// and aren't part of this engine port.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import type { Card } from "../src/rules/card.ts";
import { solveState } from "../src/bfs.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import { describe, narrate, hint, type Desc } from "../src/move.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const FIXTURES_PATH = path.resolve(
  __dirname, "../../python/conformance_fixtures.json");

interface BoardCard {
  card: { value: number; suit: number; origin_deck: number };
  state: number;
}

interface BoardStack {
  board_cards: BoardCard[];
  loc: { top: number; left: number };
}

interface Scenario {
  name: string;
  op: string;
  helper?: BoardStack[];
  trouble?: BoardStack[];
  growing?: BoardStack[];
  complete?: BoardStack[];
  expect: Record<string, unknown>;
}

function bucketToTuples(stacks: BoardStack[] | undefined): Card[][] {
  if (!stacks) return [];
  return stacks.map(s =>
    s.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as const),
  );
}

function buildRawBuckets(sc: Scenario): RawBuckets {
  return {
    helper: bucketToTuples(sc.helper),
    trouble: bucketToTuples(sc.trouble),
    growing: bucketToTuples(sc.growing),
    complete: bucketToTuples(sc.complete),
  };
}

interface RunResult {
  ok: boolean;
  msg: string;
}

function runEnumerateMoves(sc: Scenario): RunResult {
  const buckets = classifyBuckets(buildRawBuckets(sc));
  const expectedType = (sc.expect["yields"] as string) ?? "";
  const narrateSub = (sc.expect["narrate_contains"] as string) ?? "";
  const hintSub = (sc.expect["hint_contains"] as string) ?? "";
  if (!expectedType && !narrateSub && !hintSub) {
    return { ok: false, msg: "expect missing yields / narrate_contains / hint_contains" };
  }
  const moves: Desc[] = [];
  for (const [desc] of enumerateMoves(buckets)) moves.push(desc);

  if (expectedType) {
    const matches = moves.filter(d => d.type === expectedType);
    if (matches.length === 0) {
      const types = [...new Set(moves.map(d => d.type))].sort();
      return {
        ok: false,
        msg: `no ${JSON.stringify(expectedType)} move yielded; types seen: ${
          types.length > 0 ? types.join(",") : "none"
        }`,
      };
    }
  }
  if (narrateSub) {
    const narrates = moves.map(narrate);
    if (!narrates.some(n => n.includes(narrateSub))) {
      const sample = narrates.slice(0, 3);
      return { ok: false, msg: `no narrate contains ${JSON.stringify(narrateSub)}; sample: ${JSON.stringify(sample)}` };
    }
  }
  if (hintSub) {
    const hints = moves.map(hint).filter((h): h is string => h !== null);
    if (!hints.some(h => h.includes(hintSub))) {
      const sample = hints.slice(0, 3);
      return { ok: false, msg: `no hint contains ${JSON.stringify(hintSub)}; sample: ${JSON.stringify(sample)}` };
    }
  }
  return { ok: true, msg: `OK — ${moves.length} moves yielded, assertions matched` };
}

function runSolve(sc: Scenario): RunResult {
  const raw = buildRawBuckets(sc);
  const plan = solveState(raw, { maxTroubleOuter: 10, maxStates: 200000 });

  const expect = sc.expect;
  if (expect["no_plan"]) {
    if (plan === null) return { ok: true, msg: "OK — no plan, as expected" };
    return { ok: false, msg: `expected no plan; got plan of length ${plan.length}` };
  }
  const planLines = expect["plan_lines"] as string[] | undefined;
  if (planLines && planLines.length > 0) {
    if (plan === null) {
      return { ok: false, msg: `expected plan of ${planLines.length} lines; got null` };
    }
    if (plan.length === planLines.length
        && plan.every((line, i) => line === planLines[i])) {
      return { ok: true, msg: `OK — plan_lines match (${plan.length} lines)` };
    }
    // Find first divergence.
    for (let i = 0; i < Math.min(plan.length, planLines.length); i++) {
      if (plan[i] !== planLines[i]) {
        return {
          ok: false,
          msg: `plan_lines diverge at line ${i + 1}: want ${JSON.stringify(planLines[i])}, got ${JSON.stringify(plan[i])}`,
        };
      }
    }
    return {
      ok: false,
      msg: `plan_lines length: want ${planLines.length}, got ${plan.length}`,
    };
  }
  const planLength = (expect["plan_length"] as number) ?? 0;
  if (planLength > 0) {
    if (plan === null) return { ok: false, msg: `expected plan of length ${planLength}; got null` };
    if (plan.length === planLength) return { ok: true, msg: `OK — plan of length ${planLength}` };
    return { ok: false, msg: `expected plan of length ${planLength}; got ${plan.length}` };
  }
  return { ok: false, msg: "solve scenario missing expectation (no_plan / plan_length / plan_lines)" };
}

function main(): void {
  if (!fs.existsSync(FIXTURES_PATH)) {
    console.error(`no conformance fixtures at ${FIXTURES_PATH}`);
    process.exit(1);
  }
  const scenarios: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES_PATH, "utf8"));

  // v1 solve coverage: a hand-picked subset of LOW-DEPTH scenarios.
  // Picked from `corpus_sid_*` plan_lines scenarios with the shortest
  // plans + a few baseline_board ones for variety. Per the task brief,
  // "at least 5 solve cases".
  const SOLVE_ALLOWLIST = new Set<string>([
    // 1-line baseline_board plans (single push / steal / etc.)
    "baseline_board_4Cp", "baseline_board_4S", "baseline_board_4Sp",
    "baseline_board_5D", "baseline_board_5Dp", "baseline_board_KC",
    "baseline_board_KH", "baseline_board_QS",
    // Multi-line baseline_board plans (4-line peel + steal + push + push)
    "baseline_board_2D", "baseline_board_3C",
    // corpus_sid_*: low-depth scenarios from the planner_corpus DSL.
    "corpus_sid_108", "corpus_sid_112", "corpus_sid_124",
    "corpus_sid_128", "corpus_sid_132", "corpus_sid_134",
    "corpus_sid_136", "corpus_sid_138", "corpus_sid_142",
    "corpus_sid_144", "corpus_sid_148",
    // extra-corpus low-depth scenarios.
    "extra_017_6H_6Dp", "extra_018_ASp_2Sp", "extra_021_2D",
    "extra_022_3Hp", "extra_025_8C",
  ]);

  let total = 0;
  let passed = 0;
  let failed = 0;
  let skipped = 0;
  const failures: string[] = [];

  for (const sc of scenarios) {
    let res: RunResult | null = null;
    if (sc.op === "enumerate_moves") {
      res = runEnumerateMoves(sc);
    } else if (sc.op === "solve") {
      if (!SOLVE_ALLOWLIST.has(sc.name)) {
        skipped++;
        continue;
      }
      res = runSolve(sc);
    } else {
      // Other ops (build_suggestions, hint_invariant, find_open_loc,
      // hint_for_hand) are not part of the engine port.
      skipped++;
      continue;
    }
    total++;
    if (res.ok) {
      passed++;
      console.log(`PASS  ${sc.name.padEnd(50)}  ${res.msg}`);
    } else {
      failed++;
      const line = `FAIL  ${sc.name.padEnd(50)}  ${res.msg}`;
      console.log(line);
      failures.push(line);
    }
  }

  console.log();
  console.log(`${passed}/${total} passed (${skipped} skipped — outside engine scope or not in v1 solve allowlist)`);
  if (failed > 0) {
    console.log();
    console.log("FAILURES:");
    for (const f of failures) console.log("  " + f);
    process.exit(1);
  }
}

main();
