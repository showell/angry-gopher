// test_engine_conformance.ts — TS scenario-level conformance runner.
//
// Parses the .dsl scenarios natively via `conformance_dsl.ts` (no
// fixtures.json hop) and runs the TS engine against the
// `enumerate_moves` and `solve` ops:
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

import { type Card, type Rank, type Suit, type Deck, parseCardLabel } from "../core/card.ts";
// Engine conformance now exercises engine_v2 (the engine `hand_play.ts`
// and the full-game loop use). The plan-line equality
// contract loosens to "any plan that drives the augmented board to
// victory, length ≤ pinned" — engine_v2 frequently finds different
// valid plans than the bfs.ts plan-lines the JSON pins. The
// canSteal length-2 extension also made some pinned no_plan
// scenarios solvable; those are itemized in STALE_NO_PLAN.
import { findPlanForBuckets } from "../step/hand_play.ts";
import { enumerateMoves } from "../bfs/enumerator.ts";
import { narrate, hint, type Move } from "../bfs/move.ts";
import { classifyBuckets, type RawBuckets } from "../bfs/buckets.ts";
import { findPlay, formatHint } from "../step/hand_play.ts";
import { findOpenLoc, type BoardStack } from "../core/geometry.ts";
import { parseConformanceDsl } from "./conformance_dsl.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCENARIOS_DIR = path.resolve(__dirname, "../../conformance/scenarios");

// DSL files that contain TS-routed ops (enumerate_moves, solve,
// find_open_loc, hint_for_hand). The other DSLs are Elm-only or
// have their own dedicated TS runners.
const TS_ROUTED_DSLS = [
  "baseline_board_81.dsl",
  "hint_dirty_board.dsl",
  "hint_game_seed42.dsl",
  "place_stack.dsl",
  "planner.dsl",
  "planner_corpus.dsl",
  "planner_corpus_extras.dsl",
  "planner_mined.dsl",
];

const TS_ROUTED_OPS = new Set([
  "enumerate_moves",
  "solve",
  "find_open_loc",
  "hint_for_hand",
]);

interface BoardCard {
  card: { value: number; suit: number; origin_deck: number };
  state: number;
}

// Conformance-fixture stack shape (cards-with-state + optional loc).
// Distinct from `BoardStack` in geometry.ts (bare-card + loc).
interface FixtureBoardStack {
  board_cards: BoardCard[];
  loc?: { top: number; left: number };
}

interface Scenario {
  name: string;
  op: string;
  helper?: FixtureBoardStack[];
  trouble?: FixtureBoardStack[];
  growing?: FixtureBoardStack[];
  complete?: FixtureBoardStack[];
  hint_hand?: string[];
  hint_board?: string[][];
  hint_steps?: string[];
  card_count?: number;
  existing?: FixtureBoardStack[];
  expect: Record<string, unknown>;
}

function bcToCard(bc: BoardCard): Card {
  return {
    rank: bc.card.value as Rank,
    suit: bc.card.suit as Suit,
    deck: bc.card.origin_deck as Deck,
  };
}

function bucketToTuples(stacks: FixtureBoardStack[] | undefined): Card[][] {
  if (!stacks) return [];
  return stacks.map(s => s.board_cards.map(bcToCard));
}

function fixtureStackToBoardStack(fs: FixtureBoardStack): BoardStack {
  return {
    cards: fs.board_cards.map(bcToCard),
    loc: fs.loc ?? { top: 0, left: 0 },
  };
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
  const moves: Move[] = [];
  for (const [m] of enumerateMoves(buckets)) moves.push(m);

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

// Scenarios pinned as no_plan that are NOW solvable in engine_v2
// because of yesterday's canSteal length-2 extension (commit 1ceb781).
// The agent will produce a real plan; the JSON's no_plan pin is the
// stale claim. Listed loudly per
// memory/feedback_silent_skipping_is_rot.md.
const STALE_NO_PLAN: Record<string, string> = {
  extra_003_5D_6C: "canSteal length-2 unlocks a steal-from-partial path that was previously rejected",
  extra_004_5D_6C: "same pattern — steal-from-partial newly available",
  extra_008_4S_5Dp: "same pattern — steal-from-partial newly available",
  extra_011_THp: "same pattern — steal-from-partial newly available",
  extra_012_THp: "same pattern — steal-from-partial newly available",
};

function runSolve(sc: Scenario): RunResult {
  const raw = buildRawBuckets(sc);
  const result = findPlanForBuckets(raw);
  const plan = result === null ? null : result.plan;

  const expect = sc.expect;
  if (expect["no_plan"]) {
    if (plan === null) return { ok: true, msg: "OK — no plan, as expected" };
    if (sc.name in STALE_NO_PLAN) {
      return { ok: true, msg: `OK — STALE no_plan pin (${STALE_NO_PLAN[sc.name]}); engine_v2 found plan of length ${plan.length}` };
    }
    return { ok: false, msg: `expected no plan; got plan of length ${plan.length}` };
  }
  // Strict plan-line snapshot. Per
  // memory/feedback_strict_tests_no_ceiling.md: no "<= pinned"
  // length-ceiling fallback. plan_length-only scenarios that lack
  // plan_lines must be pinned up to plan_lines manually.
  const planLines = expect["plan_lines"] as string[] | undefined;
  if (planLines !== undefined && planLines.length > 0) {
    if (plan === null) {
      return { ok: false, msg: `expected plan; got null` };
    }
    const got = plan.map(p => p.line);
    if (got.length !== planLines.length || got.some((s, i) => s !== planLines[i])) {
      // Find the first divergence so the failure message points at it.
      let i = 0;
      while (i < Math.min(got.length, planLines.length) && got[i] === planLines[i]) i++;
      const expectedLine = planLines[i];
      const gotLine = got[i];
      return {
        ok: false,
        msg: `plan-line mismatch at index ${i}:`
          + `\n      expected: ${expectedLine === undefined ? "(end)" : JSON.stringify(expectedLine)}`
          + `\n      got:      ${gotLine === undefined ? "(end)" : JSON.stringify(gotLine)}`
          + `\n      (full got: length ${got.length}, expected: length ${planLines.length})`,
      };
    }
    return { ok: true, msg: `OK — plan of length ${plan.length} (exact match)` };
  }
  // No plan_lines pinned. Fail loudly so the operator either pins
  // them (preferred) or removes the scenario.
  return {
    ok: false,
    msg: "solve scenario missing plan_lines pin (and no_plan not asserted)",
  };
}

function runFindOpenLoc(sc: Scenario): RunResult {
  if (sc.card_count === undefined) {
    return { ok: false, msg: "find_open_loc scenario missing card_count" };
  }
  const wantLoc = sc.expect["loc"] as { top: number; left: number } | undefined;
  if (!wantLoc || typeof wantLoc.top !== "number" || typeof wantLoc.left !== "number") {
    return { ok: false, msg: "find_open_loc scenario missing expect.loc {top,left}" };
  }
  const existing = (sc.existing ?? []).map(fixtureStackToBoardStack);
  const got = findOpenLoc(existing, sc.card_count);
  if (got.top === wantLoc.top && got.left === wantLoc.left) {
    return { ok: true, msg: `OK — loc (${got.top}, ${got.left})` };
  }
  return {
    ok: false,
    msg: `loc mismatch: want (${wantLoc.top}, ${wantLoc.left}), got (${got.top}, ${got.left})`,
  };
}

function runHintForHand(sc: Scenario): RunResult {
  const handTokens = sc.hint_hand ?? [];
  const boardTokens = sc.hint_board ?? [];
  const wantSteps = sc.hint_steps ?? [];
  const hand: Card[] = handTokens.map(parseCardLabel);
  const board: Card[][] = boardTokens.map(stack => stack.map(parseCardLabel));
  const result = findPlay(hand, board);
  const got = formatHint(result);
  // Strict snapshot match. Per
  // memory/feedback_strict_tests_no_ceiling.md: no "<= pinned"
  // length-ceiling. Different valid hints are caught by the diff
  // and re-pinned manually, not silently accepted.
  if (result === null && wantSteps.length === 0) {
    return { ok: true, msg: "OK — null hint, as expected" };
  }
  if (result === null && wantSteps.length > 0) {
    return { ok: false, msg: `expected hint of ${wantSteps.length} steps; got null` };
  }
  if (got.length === wantSteps.length
      && got.every((step, i) => step === wantSteps[i])) {
    return { ok: true, msg: `OK — ${got.length} steps (exact match)` };
  }
  // Length or content differs. Find the first divergence so the
  // failure message points at it.
  let i = 0;
  while (i < Math.min(got.length, wantSteps.length) && got[i] === wantSteps[i]) i++;
  const expectedStep = wantSteps[i];
  const gotStep = got[i];
  return {
    ok: false,
    msg: `hint step[${i}] mismatch:`
      + `\n      expected: ${expectedStep === undefined ? "(end)" : JSON.stringify(expectedStep)}`
      + `\n      got:      ${gotStep === undefined ? "(end)" : JSON.stringify(gotStep)}`
      + `\n      (full got: ${got.length} steps; expected ${wantSteps.length})`,
  };
}

// Ops the TS engine conformance runner exercises directly.
const TS_HANDLED_OPS = new Set<string>([
  "enumerate_moves", "solve", "hint_for_hand", "find_open_loc",
]);

// Ops that exist in the fixture JSON but are out-of-scope for the TS
// port BY DESIGN. The runner reports each by name + rationale at the
// end so nothing skips silently. Per
// memory/feedback_silent_skipping_is_rot.md: skip loudly + itemized,
// or don't admit at all.
const TS_OUT_OF_SCOPE_OPS: Record<string, string> = {};

function loadScenarios(): Scenario[] {
  const out: Scenario[] = [];
  for (const dslName of TS_ROUTED_DSLS) {
    const dslPath = path.join(SCENARIOS_DIR, dslName);
    const text = fs.readFileSync(dslPath, "utf8");
    const parsed = parseConformanceDsl(text);
    for (const sc of parsed) {
      if (TS_ROUTED_OPS.has(sc.op)) {
        out.push(sc as unknown as Scenario);
      }
    }
  }
  return out;
}

function main(): void {
  const scenarios: Scenario[] = loadScenarios();

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
    const t0 = Date.now();
    let res: RunResult;
    if (sc.op === "enumerate_moves") {
      res = runEnumerateMoves(sc);
    } else if (sc.op === "solve") {
      res = runSolve(sc);
    } else if (sc.op === "hint_for_hand") {
      res = runHintForHand(sc);
    } else if (sc.op === "find_open_loc") {
      res = runFindOpenLoc(sc);
    } else {
      // Unreachable: TS_HANDLED_OPS gate above already filtered.
      throw new Error(`handled-op gate let through unrecognized op ${JSON.stringify(sc.op)}`);
    }
    const ms = Date.now() - t0;
    total++;
    const tag = ms >= 100 ? `  [${ms}ms]` : "";
    if (res.ok) {
      passed++;
      console.log(`PASS  ${sc.name.padEnd(50)}  ${res.msg}${tag}`);
    } else {
      failed++;
      const line = `FAIL  ${sc.name.padEnd(50)}  ${res.msg}${tag}`;
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
