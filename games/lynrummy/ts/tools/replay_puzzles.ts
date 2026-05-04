// replay_puzzles.ts — emit conformance DSL for every puzzle in
// games/lynrummy/puzzles/puzzles.json. Two output files, one
// invocation:
//
//   1. conformance/scenarios/planner_puzzles.dsl
//      `op: solve` scenarios pinning the canonical plan-lines for
//      each puzzle. Drives test_engine_conformance's strict
//      plan_lines gate.
//
//   2. conformance/scenarios/puzzle_walkthroughs.dsl
//      `op: replay_invariant` scenarios pinning the FULL primitive
//      sequence for each puzzle (verb expansion + geometry pre-
//      flight, threaded across moves). Drives
//      test_replay_walkthroughs.
//
// Both files are auto-generated; the engine output IS the spec.
// When the engine produces different plans / primitives, the
// conformance gate fails — the operator inspects the diff,
// decides whether the new behavior is better (re-run + commit) or
// a regression (fix the engine), and re-runs this tool to
// re-pin.
//
// Usage:
//   node tools/replay_puzzles.ts

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../src/rules/card.ts";
import { cardLabel } from "../src/rules/card.ts";
import type { BoardStack } from "../src/geometry.ts";
import type { Primitive } from "../src/primitives.ts";
import { applyLocally } from "../src/primitives.ts";
import { expandVerb } from "../src/verbs.ts";
import { solveStateWithDescs } from "../src/engine_v2.ts";
import {
  classifyStack,
  KIND_RUN, KIND_RB, KIND_SET,
} from "../src/classified_card_stack.ts";

// --- Puzzle JSON shape -----------------------------------------------

interface JsonCard { value: number; suit: number; origin_deck: number }
interface JsonBoardCard { card: JsonCard; state: number }
interface JsonLoc { top: number; left: number }
interface JsonStack { board_cards: JsonBoardCard[]; loc: JsonLoc }
interface JsonInitialState { board: JsonStack[] }
interface JsonPuzzle { name: string; title: string; initial_state: JsonInitialState }
interface JsonCatalog { puzzles: JsonPuzzle[] }

function decodeBoard(stacks: JsonStack[]): BoardStack[] {
  return stacks.map(s => ({
    cards: s.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as Card),
    loc: { top: s.loc.top, left: s.loc.left },
  }));
}

// --- Bucket partition (mirror of engine_entry.solveBoard) -----------

interface Buckets {
  helper: Card[][];
  trouble: Card[][];
}

function partitionBoard(board: readonly BoardStack[]): Buckets {
  const helper: Card[][] = [];
  const trouble: Card[][] = [];
  for (const stack of board) {
    const ccs = classifyStack(stack.cards);
    const cards = stack.cards as Card[];
    if (ccs !== null && (ccs.kind === KIND_RUN || ccs.kind === KIND_RB || ccs.kind === KIND_SET)) {
      helper.push(cards);
    } else {
      trouble.push(cards);
    }
  }
  return { helper, trouble };
}

// --- Formatting helpers ----------------------------------------------

function dslStack(cards: readonly Card[]): string {
  return cards.map(cardLabel).join(" ");
}

/** Escape a plan-line for embedding in a DSL double-quoted string.
 *  Plan-line text only uses cardLabel + a fixed alphabet; only `"`
 *  and `\` need escaping. */
function dslQuote(s: string): string {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

/** Render a Primitive in the action-line syntax shared by
 *  replay_walkthroughs.dsl + verb_to_primitives.dsl + the parser
 *  in test_replay_walkthroughs.parseActionLine. The sim-board
 *  argument is needed because primitives reference stacks by
 *  position; we look up the cards at that position to render the
 *  content-form expected by the DSL. */
function primToDslLine(p: Primitive, sim: readonly BoardStack[]): string {
  switch (p.action) {
    case "split":
      return `split [${dslStack(sim[p.stackIndex]!.cards)}]@${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack [${dslStack(sim[p.sourceStack]!.cards)}]`
        + ` -> [${dslStack(sim[p.targetStack]!.cards)}] /${p.side}`;
    case "merge_hand":
      return `merge_hand ${cardLabel(p.handCard)}`
        + ` -> [${dslStack(sim[p.targetStack]!.cards)}] /${p.side}`;
    case "place_hand":
      return `place_hand ${cardLabel(p.handCard)} -> (${p.loc.top},${p.loc.left})`;
    case "move_stack":
      return `move_stack [${dslStack(sim[p.stackIndex]!.cards)}]`
        + ` -> (${p.newLoc.top},${p.newLoc.left})`;
  }
}

// --- Per-puzzle solve + primitive expansion --------------------------
//
// A puzzle "walkthrough" is the full primitive sequence the engine
// would emit if you let it play the puzzle through to victory:
// solve → for each plan-desc, expandVerb against the threading sim,
// concatenate. No hand cards (puzzles are board-only).

interface PuzzleResult {
  readonly puzzle: JsonPuzzle;
  readonly board: readonly BoardStack[];
  readonly buckets: Buckets;
  readonly planLines: readonly string[] | null;
  readonly primitives: readonly { prim: Primitive; simAtEmit: readonly BoardStack[] }[];
}

function runPuzzle(p: JsonPuzzle): PuzzleResult {
  const board = decodeBoard(p.initial_state.board);
  const buckets = partitionBoard(board);
  const plan = solveStateWithDescs({
    helper: buckets.helper, trouble: buckets.trouble, growing: [], complete: [],
  });
  if (plan === null) {
    return { puzzle: p, board, buckets, planLines: null, primitives: [] };
  }
  const planLines: string[] = plan.map(pl => pl.line);
  const primitives: { prim: Primitive; simAtEmit: readonly BoardStack[] }[] = [];
  let sim: readonly BoardStack[] = board;
  for (const pl of plan) {
    const prims = expandVerb(pl.desc, sim, new Set());
    for (const prim of prims) {
      primitives.push({ prim, simAtEmit: sim });
      sim = applyLocally(sim, prim);
    }
  }
  return { puzzle: p, board, buckets, planLines, primitives };
}

// --- DSL emitters ----------------------------------------------------

const PLANNER_HEADER =
  "# AUTO-GENERATED by tools/replay_puzzles.ts.\n" +
  "# Do NOT hand-edit. Re-run the exporter to refresh.\n" +
  "#\n" +
  "# Each scenario captures the canonical TS solver's plan for\n" +
  "# one entry in games/lynrummy/puzzles/puzzles.json. The plan\n" +
  "# you see is the plan the engine produces RIGHT NOW for that\n" +
  "# board — when reading, treat \"expected\" as a snapshot of\n" +
  "# \"actual\". Drift between this file and the engine surfaces\n" +
  "# at the conformance gate; regenerate to update the spec.\n" +
  "\n";

const WALKTHROUGH_HEADER =
  "# AUTO-GENERATED by tools/replay_puzzles.ts.\n" +
  "# Do NOT hand-edit. Re-run the exporter to refresh.\n" +
  "#\n" +
  "# Per-puzzle replay-invariant walkthrough: for each entry in\n" +
  "# games/lynrummy/puzzles/puzzles.json, solve the board and pin\n" +
  "# the FULL primitive sequence (verb expansion + geometry pre-\n" +
  "# flight, threaded across moves). The runner asserts the\n" +
  "# replay FSM and the eager applier agree on the final model\n" +
  "# AND that the puzzle ends in victory.\n" +
  "#\n" +
  "# Hand-origin actions (merge_hand, place_hand) don't appear —\n" +
  "# puzzles are board-only.\n" +
  "\n";

function emitPlannerScenario(r: PuzzleResult): string {
  const lines: string[] = [];
  lines.push(`scenario puzzle_${r.puzzle.name}`);
  lines.push(`  desc: Replay of ${r.puzzle.title}. Auto-generated by tools/replay_puzzles.ts.`);
  lines.push(`  op: solve`);
  lines.push(`  helper:`);
  for (const stack of r.buckets.helper) {
    lines.push(`    at (0,0): ${dslStack(stack)}`);
  }
  lines.push(`  trouble:`);
  for (const stack of r.buckets.trouble) {
    lines.push(`    at (0,0): ${dslStack(stack)}`);
  }
  lines.push(`  expect:`);
  if (r.planLines === null) {
    lines.push(`    # solver returned NULL (no plan within budget)`);
    lines.push(`    plan_lines:`);
  } else {
    lines.push(`    plan_lines:`);
    for (const planLine of r.planLines) {
      lines.push(`      - ${dslQuote(planLine)}`);
    }
  }
  return lines.join("\n") + "\n\n";
}

function emitWalkthroughScenario(r: PuzzleResult): string {
  const lines: string[] = [];
  lines.push(`scenario walkthrough_puzzle_${r.puzzle.name}`);
  lines.push(`  desc: Full primitive walkthrough for ${r.puzzle.title}; replay + eager agree, final board victory.`);
  lines.push(`  op: replay_invariant`);
  lines.push(`  board:`);
  for (const stack of r.board) {
    lines.push(`    at (${stack.loc.top},${stack.loc.left}): ${dslStack(stack.cards)}`);
  }
  if (r.primitives.length === 0) {
    lines.push(`  # solver returned no plan; no primitives to walk`);
    lines.push(`  actions:`);
  } else {
    lines.push(`  actions:`);
    for (const { prim, simAtEmit } of r.primitives) {
      lines.push(`    - ${primToDslLine(prim, simAtEmit)}`);
    }
  }
  return lines.join("\n") + "\n\n";
}

// --- Entry point -----------------------------------------------------

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const catalogPath = path.resolve(here, "../../puzzles/puzzles.json");
  const plannerOutPath = path.resolve(here, "../../conformance/scenarios/planner_puzzles.dsl");
  const walkthroughOutPath = path.resolve(here, "../../conformance/scenarios/puzzle_walkthroughs.dsl");

  const raw = fs.readFileSync(catalogPath, "utf8");
  const catalog: JsonCatalog = JSON.parse(raw);

  let plannerBody = PLANNER_HEADER;
  let walkthroughBody = WALKTHROUGH_HEADER;
  for (const p of catalog.puzzles) {
    const r = runPuzzle(p);
    plannerBody += emitPlannerScenario(r);
    walkthroughBody += emitWalkthroughScenario(r);
    console.log(
      `  ${p.name.padEnd(20)} `
      + `plan=${r.planLines === null ? "null" : String(r.planLines.length)} `
      + `primitives=${r.primitives.length}`,
    );
  }
  fs.writeFileSync(plannerOutPath, plannerBody);
  fs.writeFileSync(walkthroughOutPath, walkthroughBody);
  console.log();
  console.log(`Wrote ${plannerOutPath}`);
  console.log(`Wrote ${walkthroughOutPath}`);
}

main();
