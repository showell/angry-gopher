// test_engine_conformance.ts — TS scenario-level conformance runner.
//
// Reads `conformance/fixtures.json` (the canonical JSON emitted by
// `cmd/fixturegen` from the DSL scenarios) and runs the TS engine
// against the `enumerate_moves` and `solve` ops:
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
import { parseCardLabel } from "../src/rules/card.ts";
// Engine conformance now exercises engine_v2 (the engine `hand_play.ts`
// and `agent_player.ts` use). The plan-line equality
// contract loosens to "any plan that drives the augmented board to
// victory, length ≤ pinned" — engine_v2 frequently finds different
// valid plans than the bfs.ts plan-lines the JSON pins. The
// canSteal length-2 extension also made some pinned no_plan
// scenarios solvable; those are itemized in STALE_NO_PLAN.
import { solveStateWithDescs } from "../src/engine_v2.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import { describe, narrate, hint, type Desc } from "../src/move.ts";
import { classifyBuckets, type Buckets, type RawBuckets } from "../src/buckets.ts";
import { findPlay, formatHint } from "../src/hand_play.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { findOpenLoc, type BoardStack } from "../src/geometry.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const FIXTURES_PATH = path.resolve(
  __dirname, "../../conformance/fixtures.json");

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

function bucketToTuples(stacks: FixtureBoardStack[] | undefined): Card[][] {
  if (!stacks) return [];
  return stacks.map(s =>
    s.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as const),
  );
}

function fixtureStackToBoardStack(fs: FixtureBoardStack): BoardStack {
  return {
    cards: fs.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as const),
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

function applyPlan(initial: Buckets, plan: readonly { desc: Desc }[]): Buckets {
  let state: Buckets = initial;
  for (let step = 0; step < plan.length; step++) {
    const want = describe(plan[step]!.desc);
    let matched: Buckets | null = null;
    for (const [desc, next] of enumerateMoves(state)) {
      if (describe(desc) === want) { matched = next; break; }
    }
    if (matched === null) {
      throw new Error(`step ${step + 1}: enumerator did not yield matching move "${want}"`);
    }
    state = matched;
  }
  return state;
}

function isCleanFinal(b: Buckets): { ok: boolean; msg: string } {
  if (b.trouble.length > 0) {
    return { ok: false, msg: `${b.trouble.length} trouble stack(s) remain` };
  }
  for (const bucket of [b.helper, b.growing, b.complete]) {
    for (const stack of bucket) {
      const ccs = classifyStack(stack.cards);
      if (ccs === null || ccs.n < 3) {
        return { ok: false, msg: `final stack [${stack.cards.map(c => c.join(",")).join(" ")}] not length-3+ legal` };
      }
      if (ccs.kind !== "run" && ccs.kind !== "rb" && ccs.kind !== "set") {
        return { ok: false, msg: `final stack kind ${ccs.kind} not run/rb/set` };
      }
    }
  }
  return { ok: true, msg: "" };
}

function runSolve(sc: Scenario): RunResult {
  const raw = buildRawBuckets(sc);
  const plan = solveStateWithDescs(raw, { maxTroubleOuter: 10, maxStates: 200000 });

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
  // plan_lines are repaired up to plan_lines via --repair the same
  // way solve scenarios are.
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
    msg: "solve scenario missing plan_lines pin (and no_plan not asserted) — repair with --repair",
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
  // and re-pinned via --repair, not silently accepted.
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

function main(): void {
  if (!fs.existsSync(FIXTURES_PATH)) {
    console.error(`no conformance fixtures at ${FIXTURES_PATH}`);
    process.exit(1);
  }
  let scenarios: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES_PATH, "utf8"));

  // CLI parsing — order-insensitive: any non-flag arg is a name
  // substring filter; `--repair` switches into pin-rewrite mode.
  const args = process.argv.slice(2);
  const repair = args.includes("--repair");
  const filter = args.find(a => !a.startsWith("--"));
  if (filter !== undefined) {
    scenarios = scenarios.filter(sc => sc.name.includes(filter));
    if (scenarios.length === 0) {
      console.error(`no scenario name matches ${JSON.stringify(filter)}`);
      process.exit(1);
    }
    console.log(`Filtered to ${scenarios.length} scenario(s) matching ${JSON.stringify(filter)}.`);
  }
  if (repair) {
    console.log("REPAIR MODE: solve-scenario plan_lines and hint_for_hand");
    console.log("expect_steps pins will be rewritten from current engine");
    console.log("output. Re-run fixturegen after repair.");
    console.log();
  }
  // Repair-mode collection: scenarioName → {kind, lines}.
  // RepairContent is declared at module scope below.
  const repairs = new Map<string, RepairContent>();

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
      if (repair) {
        // In repair mode: run the engine, capture plan-lines for
        // every non-no_plan solve scenario. Covers two cases:
        //   - existing plan_lines block: replaced with current engine output
        //   - existing plan_length pin (no plan_lines): converted to plan_lines
        if (sc.expect["no_plan"]) {
          res = runSolve(sc);  // no_plan stays no_plan; nothing to capture
        } else {
          const raw = buildRawBuckets(sc);
          const plan = solveStateWithDescs(raw, { maxTroubleOuter: 10, maxStates: 200000 });
          if (plan === null) {
            res = { ok: false, msg: `REPAIR: engine returned null for pinned scenario` };
          } else {
            repairs.set(sc.name, { kind: "plan_lines", lines: plan.map(p => p.line) });
            res = { ok: true, msg: `REPAIRED — ${plan.length} plan-line(s) recorded` };
          }
        }
      } else {
        res = runSolve(sc);
      }
    } else if (sc.op === "hint_for_hand") {
      if (repair) {
        // Capture engine's current hint steps and rewrite the DSL's
        // expect_steps block.
        const handTokens = sc.hint_hand ?? [];
        const boardTokens = sc.hint_board ?? [];
        const hand: Card[] = handTokens.map(parseCardLabel);
        const board: Card[][] = boardTokens.map(stack => stack.map(parseCardLabel));
        const result = findPlay(hand, board);
        const got = formatHint(result);
        repairs.set(sc.name, { kind: "expect_steps", lines: [...got] });
        res = { ok: true, msg: `REPAIRED — ${got.length} step(s) recorded` };
      } else {
        res = runHintForHand(sc);
      }
    } else if (sc.op === "find_open_loc") {
      res = runFindOpenLoc(sc);
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

  if (repair && repairs.size > 0) {
    console.log();
    console.log(`Rewriting ${repairs.size} pin block(s) in DSL files...`);
    rewriteDslPins(repairs);
    console.log("Done. Now run `go run ./cmd/fixturegen ...` to refresh fixtures.json.");
  }

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

/**
 * Repair-mode helper: scan every .dsl file in conformance/scenarios/
 * for `scenario <name>` headers, and where the scenario name is in
 * `repairs`, rewrite the appropriate pin block with the captured
 * engine output. Idempotent — re-run is a no-op if the engine still
 * produces the same lines.
 *
 * Two block shapes are handled:
 *
 *   plan_lines (op: solve, indent under `expect:`):
 *     scenario <name>
 *       ...
 *       expect:
 *         plan_lines:
 *           - "<line>"
 *
 *     A scenario carrying `plan_length: N` instead of `plan_lines:`
 *     gets the `plan_length:` line replaced with a `plan_lines:`
 *     block in the same place — converting the relaxed pin into a
 *     strict pin.
 *
 *   expect_steps (op: hint_for_hand, top-level under scenario):
 *     scenario <name>
 *       ...
 *       expect_steps:
 *         - <step>
 *         - <step>
 */
type RepairContent =
  | { kind: "plan_lines"; lines: string[] }
  | { kind: "expect_steps"; lines: string[] };

function rewriteDslPins(repairs: Map<string, RepairContent>): void {
  const dslDir = path.resolve(__dirname, "../../conformance/scenarios");
  const dslFiles = fs.readdirSync(dslDir)
    .filter(f => f.endsWith(".dsl"))
    .map(f => path.join(dslDir, f));

  let touchedFiles = 0;
  let touchedScenarios = 0;

  for (const file of dslFiles) {
    const original = fs.readFileSync(file, "utf8");
    const lines = original.split("\n");
    let changed = false;

    let i = 0;
    while (i < lines.length) {
      const m = lines[i]!.match(/^scenario\s+(\S+)\s*$/);
      if (!m) { i++; continue; }
      const name = m[1]!;
      const repair = repairs.get(name);
      if (repair === undefined) { i++; continue; }

      // Scenario block extent: from i+1 up to (but not including)
      // the next `^scenario ` line or end-of-file.
      let blockEnd = i + 1;
      while (blockEnd < lines.length && !lines[blockEnd]!.match(/^scenario\s+\S+\s*$/)) {
        blockEnd++;
      }

      if (repair.kind === "plan_lines") {
        const result = rewritePlanLinesBlock(lines, i + 1, blockEnd, repair.lines);
        if (result.changed) {
          changed = true;
          touchedScenarios++;
        }
        i = result.nextI;
      } else if (repair.kind === "expect_steps") {
        const result = rewriteExpectStepsBlock(lines, i + 1, blockEnd, repair.lines);
        if (result.changed) {
          changed = true;
          touchedScenarios++;
        }
        i = result.nextI;
      } else {
        i++;
      }
    }

    if (changed) {
      fs.writeFileSync(file, lines.join("\n"));
      touchedFiles++;
      console.log(`  ${path.basename(file)} — updated`);
    }
  }
  console.log(`Touched ${touchedScenarios} scenarios across ${touchedFiles} file(s).`);
}

/** Rewrite (or convert) the plan_lines/plan_length pin under
 *  `expect:`. `lines` is the file split by lines; `start` and `end`
 *  bound the scenario block. Mutates `lines` in place. */
function rewritePlanLinesBlock(
  lines: string[],
  start: number,
  end: number,
  newPlanLines: readonly string[],
): { changed: boolean; nextI: number } {
  const replacement = newPlanLines.map(l => `      - ${dslQuoteLine(l)}`);

  // Look first for an existing `plan_lines:` line.
  for (let j = start; j < end; j++) {
    if (lines[j]!.match(/^\s*plan_lines:\s*$/)) {
      let endIdx = j + 1;
      while (endIdx < lines.length && /^      - ".*"$/.test(lines[endIdx]!)) {
        endIdx++;
      }
      lines.splice(j + 1, endIdx - (j + 1), ...replacement);
      return { changed: true, nextI: j + 1 + replacement.length };
    }
  }
  // No plan_lines block. Look for a `plan_length: N` line and
  // convert it to a plan_lines block.
  for (let j = start; j < end; j++) {
    if (lines[j]!.match(/^\s*plan_length:\s*\d+\s*$/)) {
      lines.splice(j, 1, `    plan_lines:`, ...replacement);
      return { changed: true, nextI: j + 1 + replacement.length };
    }
  }
  return { changed: false, nextI: start };
}

/** Rewrite the expect_steps pin (hint_for_hand). `start`/`end`
 *  bound the scenario block. Mutates `lines` in place. */
function rewriteExpectStepsBlock(
  lines: string[],
  start: number,
  end: number,
  newSteps: readonly string[],
): { changed: boolean; nextI: number } {
  const replacement = newSteps.map(s => `    - ${s}`);
  for (let j = start; j < end; j++) {
    if (lines[j]!.match(/^\s*expect_steps:\s*$/)) {
      let endIdx = j + 1;
      while (endIdx < lines.length && /^    - /.test(lines[endIdx]!)) {
        endIdx++;
      }
      lines.splice(j + 1, endIdx - (j + 1), ...replacement);
      return { changed: true, nextI: j + 1 + replacement.length };
    }
  }
  return { changed: false, nextI: start };
}

/**
 * Quote a plan-line string for the DSL `- "..."` form. The DSL
 * uses double-quoted strings; only `"` and `\` need escaping.
 * Plan-line text contains neither in normal output (cards, arrows,
 * brackets, semicolons all pass through unescaped).
 */
function dslQuoteLine(s: string): string {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

main();
