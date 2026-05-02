// test_engine_conformance.ts — TS scenario-level conformance runner.
//
// Reads `python/conformance_fixtures.json` (the same JSON the Python
// `test_dsl_conformance.py` consumes) and runs the TS engine against
// the `enumerate_moves` and `solve` ops:
//
//   - All `enumerate_moves` scenarios — assert the matching `yields`
//     type (or `narrate_contains` / `hint_contains` substring) is
//     produced by the TS engine.
//   - All `solve` scenarios with any defined expectation
//     (`no_plan` / `plan_lines` / `plan_length`) are admitted. The
//     v1 hand-picked SOLVE_ALLOWLIST kept earlier tiers small while
//     the engine was being verified; programmatic admission by
//     expectation-shape replaced it once the engine proved out.
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

// Ops the TS engine conformance runner exercises directly.
const TS_HANDLED_OPS = new Set<string>(["enumerate_moves", "solve"]);

// Ops that exist in the fixture JSON but are out-of-scope for the TS
// port BY DESIGN. The runner reports each by name + rationale at the
// end so nothing skips silently. Per
// memory/feedback_silent_skipping_is_rot.md: skip loudly + itemized,
// or don't admit at all.
const TS_OUT_OF_SCOPE_OPS: Record<string, string> = {
  find_open_loc: "tested in Python + Elm; UI placement geometry, not BFS",
  // hint_for_hand is in-scope-but-not-yet-ported. The TS port will gain
  // a hand-aware outer loop (mirror of python/agent_prelude.find_play),
  // then this entry moves to TS_HANDLED_OPS. Tracked: TS_BFS_PORT step 2.
  hint_for_hand: "TS hand-aware outer loop port pending (TS_BFS_PORT step 2)",
};

function main(): void {
  if (!fs.existsSync(FIXTURES_PATH)) {
    console.error(`no conformance fixtures at ${FIXTURES_PATH}`);
    process.exit(1);
  }
  const scenarios: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES_PATH, "utf8"));

  let total = 0;
  let passed = 0;
  let failed = 0;
  const failures: string[] = [];
  const outOfScopeCounts: Record<string, number> = {};
  const unknownOpCounts: Record<string, number> = {};

  for (const sc of scenarios) {
    if (!TS_HANDLED_OPS.has(sc.op)) {
      if (sc.op in TS_OUT_OF_SCOPE_OPS) {
        outOfScopeCounts[sc.op] = (outOfScopeCounts[sc.op] ?? 0) + 1;
      } else {
        unknownOpCounts[sc.op] = (unknownOpCounts[sc.op] ?? 0) + 1;
      }
      continue;
    }
    let res: RunResult | null = null;
    if (sc.op === "enumerate_moves") {
      res = runEnumerateMoves(sc);
    } else if (sc.op === "solve") {
      res = runSolve(sc);
    } else {
      // Unreachable: TS_HANDLED_OPS gate above already filtered.
      throw new Error(`handled-op gate let through unrecognized op ${JSON.stringify(sc.op)}`);
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
  console.log(`${passed}/${total} passed`);
  if (Object.keys(outOfScopeCounts).length > 0) {
    console.log();
    console.log("Out-of-scope by design (handled in Python and/or Elm):");
    for (const [op, n] of Object.entries(outOfScopeCounts).sort()) {
      console.log(`  ${op} (${n} scenarios) — ${TS_OUT_OF_SCOPE_OPS[op]}`);
    }
  }
  if (Object.keys(unknownOpCounts).length > 0) {
    console.log();
    console.log("UNRECOGNIZED OPS (neither handled nor declared out-of-scope):");
    for (const [op, n] of Object.entries(unknownOpCounts).sort()) {
      console.log(`  ${op} (${n} scenarios) — add to TS_HANDLED_OPS or TS_OUT_OF_SCOPE_OPS`);
    }
    process.exit(1);
  }
  if (failed > 0) {
    console.log();
    console.log("FAILURES:");
    for (const f of failures) console.log("  " + f);
    process.exit(1);
  }
}

main();
