// replay_puzzles.ts — render the canonical TS solver's output for
// each puzzle in games/lynrummy/puzzles/puzzles.json, in DSL-like
// shorthand that matches `tools/show_session.py`'s format.
//
// Purpose: surface solver / planner flaws that are hard to see in
// the live UI but obvious on paper. The output shows the initial
// board, then for each plan line: the engine's DSL description,
// followed by the primitive sequence the verb→primitive +
// geometry pipeline emits. When the planner does something silly
// (e.g. splits a Set into singletons and immediately re-pairs two
// of them), the primitive list makes it visible at a glance.
//
// The puzzles catalog is small and stable, so this is the natural
// debug surface: every puzzle the gallery ships gets walked here.
//
// Usage:
//   node tools/replay_puzzles.ts            # all puzzles
//   node tools/replay_puzzles.ts <name>     # just the named puzzle
//                                           # (substring match, case-sensitive)
//
// Output goes to stdout.
//
// DSL conventions (matching tools/show_session.py):
//   - Cards: rank+suit, e.g. KS, 7H, AC
//   - Deck-2 cards get a trailing apostrophe, e.g. 8C', QC'
//   - Stacks: one per row, space-separated cards
//
// Translates the engine's native `:1` deck suffix (cardLabel)
// into the apostrophe form so the report reads in one consistent
// shorthand throughout.

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../src/rules/card.ts";
import { cardLabel } from "../src/rules/card.ts";
import type { BoardStack } from "../src/geometry.ts";
import { applyLocally } from "../src/primitives.ts";
import type { Primitive } from "../src/primitives.ts";
import { expandVerb } from "../src/verbs.ts";
import { solveStateWithDescs } from "../src/engine_v2.ts";
import {
  classifyStack,
  KIND_RUN, KIND_RB, KIND_SET,
} from "../src/classified_card_stack.ts";

// --- DSL shorthand helpers -------------------------------------------

/** Convert engine `8C:1` form to show_session.py's `8C'` form. */
function dslLabel(c: Card): string {
  const base = cardLabel(c);
  return base.replace(/:1$/, "'").replace(/:0$/, "");
}

function dslStack(cards: readonly Card[]): string {
  return cards.map(dslLabel).join(" ");
}

/** Translate any engine plan-line text from `:1` to `'` form so the
 *  full report reads consistently. The engine only ever emits
 *  `:1` (deck 0 has no suffix), so this is a single substitution. */
function dslLine(line: string): string {
  return line.replace(/:1\b/g, "'");
}

// --- Puzzle JSON shape -----------------------------------------------
//
// Mirrors what views/puzzles.go ships: { puzzles: [{ name, title,
// initial_state: { board: [{board_cards: [{card: {...}, state}], loc},
// ...], hands: [...], deck: [...], ... } } ...] }. We only need the
// board's cards + locs for replay.

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
//
// Same as `engine_entry.ts solveBoard`'s helper-vs-trouble partition;
// kept here so this tool doesn't depend on the browser-bundle entry
// module.

function buckets(board: readonly BoardStack[]): {
  helper: Card[][]; trouble: Card[][]; growing: Card[][]; complete: Card[][];
} {
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
  return { helper, trouble, growing: [], complete: [] };
}

// --- Primitive rendering ---------------------------------------------
//
// Each primitive is rendered against the sim it executes against —
// we look up stack content by index so the report shows what was
// actually moved (not just an index). Sim is threaded forward across
// the move's primitive sequence the same way verbs.ts threads it.

function renderPrim(prim: Primitive, sim: readonly BoardStack[]): string {
  switch (prim.action) {
    case "split": {
      const stack = sim[prim.stackIndex]!;
      return `split [${dslStack(stack.cards)}] @ index ${prim.cardIndex}`;
    }
    case "merge_stack": {
      const src = sim[prim.sourceStack]!;
      const tgt = sim[prim.targetStack]!;
      return `merge_stack [${dslStack(src.cards)}] ${prim.side} onto [${dslStack(tgt.cards)}]`;
    }
    case "merge_hand": {
      const tgt = sim[prim.targetStack]!;
      return `merge_hand ${dslLabel(prim.handCard)} ${prim.side} onto [${dslStack(tgt.cards)}]`;
    }
    case "place_hand":
      return `place_hand ${dslLabel(prim.handCard)} @ (${prim.loc.top}, ${prim.loc.left})`;
    case "move_stack": {
      const stack = sim[prim.stackIndex]!;
      return `move_stack [${dslStack(stack.cards)}] → (${prim.newLoc.top}, ${prim.newLoc.left})`;
    }
  }
}

// --- Per-puzzle replay -----------------------------------------------

function replayPuzzle(p: JsonPuzzle): void {
  console.log(`=== ${p.title} ===`);

  const board = decodeBoard(p.initial_state.board);
  console.log("initial board:");
  for (const stack of board) {
    console.log(`  ${dslStack(stack.cards)}`);
  }

  const plan = solveStateWithDescs(buckets(board));
  if (plan === null) {
    console.log("\n(no plan within budget)");
    console.log();
    return;
  }
  if (plan.length === 0) {
    console.log("\n(board is already clean — empty plan)");
    console.log();
    return;
  }

  console.log("\nplan:");
  let sim: readonly BoardStack[] = board;
  for (let i = 0; i < plan.length; i++) {
    const planLine = plan[i]!;
    console.log(`  [${i + 1}] ${dslLine(planLine.line)}`);
    const prims = expandVerb(planLine.desc, sim, new Set());
    if (prims.length === 0) {
      console.log("      (no primitives — engine bug?)");
    } else {
      console.log(`      primitives (${prims.length}):`);
      for (const p of prims) {
        console.log(`        ${renderPrim(p, sim)}`);
        sim = applyLocally(sim, p);
      }
    }
  }
  console.log();
}

// --- Entry point -----------------------------------------------------

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const catalogPath = path.resolve(here, "../../puzzles/puzzles.json");
  const raw = fs.readFileSync(catalogPath, "utf8");
  const catalog: JsonCatalog = JSON.parse(raw);

  const filter = process.argv[2];  // optional substring match on name
  const puzzles = filter !== undefined
    ? catalog.puzzles.filter(p => p.name.includes(filter))
    : catalog.puzzles;

  if (puzzles.length === 0) {
    console.log(`No puzzles match filter ${JSON.stringify(filter)}.`);
    return;
  }

  for (const p of puzzles) {
    replayPuzzle(p);
  }
}

main();
