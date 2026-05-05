// engine_entry.ts — browser-bundle entry point for the TS engine.
//
// Re-exports a tight surface for esbuild → IIFE bundling so the Elm
// puzzles UI can call the canonical solver via Elm ports + JS glue.
// Internals stay camelCase / typed; the JS glue handles snake_case
// translation at the wire boundary.

import type { Card } from "./rules/card.ts";
import type { PlanLine } from "./engine_v2.ts";
import { solveStateWithDescs } from "./engine_v2.ts";
import {
  classifyStack,
  KIND_RUN,
  KIND_RB,
  KIND_SET,
} from "./classified_card_stack.ts";
import type { BoardStack } from "./geometry.ts";
import { applyLocally } from "./primitives.ts";
import { expandVerb } from "./verbs.ts";
import { findPlay, formatHint } from "./hand_play.ts";
import { primToWire, type WireActionJson } from "./wire_json.ts";

/**
 * Board-shaped entry point. Each board stack is a list of cards
 * (Card tuples). Partitions stacks into helper (complete groups:
 * run / rb / set) vs trouble (everything else), then delegates to
 * `solveStateWithDescs`. Mirrors `Game.Agent.Bfs.solveBoard` in
 * Elm — same partition, same surface.
 *
 * Returns the SHORTEST plan (PlanLine[]) found within the engine's
 * default budget, or null if no plan exists / budget exhausted.
 *
 * Used by the puzzles HINT button. Locations aren't needed because
 * hint output is text-only — no primitives to lay out.
 */
export function solveBoard(
  board: readonly (readonly Card[])[],
): readonly PlanLine[] | null {
  return solveBucketsFromCardLists(board);
}

/**
 * Agent-play entry point. Like `solveBoard` but threads geometry
 * through the verb expansion so callers get back per-move
 * primitive batches in Elm-wire JSON shape.
 *
 * Each batch is `{ line, wire_actions }` where `line` is the
 * canonical DSL string for one logical move and `wire_actions` is
 * the primitive sequence (in `Game.WireAction` JSON shape) that
 * realizes it on the live board. The Elm side caches batches in
 * `agentProgram` and consumes one per click — same per-move-step
 * walking semantics as the legacy Elm-BFS path.
 *
 * Each `BoardStack` carries `{cards, loc}` matching `geometry.ts`.
 * Locations are required because verb expansion does geometry-
 * aware planning (interior splits relocate, end-splits pre-flight,
 * pushes find open locs, etc.).
 */
export function agentPlay(
  board: readonly BoardStack[],
): readonly { line: string; wire_actions: readonly WireActionJson[] }[] | null {
  const cardLists = board.map(s => s.cards);
  const plan = solveBucketsFromCardLists(cardLists);
  if (plan === null) return null;

  // Thread sim forward across moves. Each desc expands against the
  // current sim, then the resulting primitives advance sim before
  // the next desc expands.
  let sim: readonly BoardStack[] = board;
  const out: { line: string; wire_actions: WireActionJson[] }[] = [];
  for (const planLine of plan) {
    const prims = expandVerb(planLine.desc, sim, new Set());
    const wireActions: WireActionJson[] = [];
    for (const p of prims) {
      wireActions.push(primToWire(p, sim));
      sim = applyLocally(sim, p);
    }
    out.push({ line: planLine.line, wire_actions: wireActions });
  }
  return out;
}

function solveBucketsFromCardLists(
  board: readonly (readonly Card[])[],
): readonly PlanLine[] | null {
  const helper: Card[][] = [];
  const trouble: Card[][] = [];
  for (const stack of board) {
    const ccs = classifyStack(stack);
    if (ccs !== null
      && (ccs.kind === KIND_RUN || ccs.kind === KIND_RB || ccs.kind === KIND_SET)) {
      helper.push(stack as Card[]);
    } else {
      trouble.push(stack as Card[]);
    }
  }
  return solveStateWithDescs({
    helper,
    trouble,
    growing: [],
    complete: [],
  });
}

/**
 * Full-game hint entry point. Given the active player's hand and
 * the live board, return the rendered hint as a flat list of step
 * strings: `["place [<cards>] from hand", "<plan-line>", ...]`,
 * or `[]` if no playable hand card was found.
 *
 * Wraps `findPlay` (hand-aware outer loop — triple-in-hand →
 * pair projections → singleton projections → shortest plan) and
 * `formatHint` (renderer). The Elm UI displays `lines` verbatim
 * in the status bar; refining hint phrasing belongs in
 * `hand_play.ts:formatHint`, not here.
 */
export function gameHintLines(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): readonly string[] {
  return formatHint(findPlay(hand, board));
}

// Re-exports — used by tests and by the agent_player code path.
export { solveStateWithDescs } from "./engine_v2.ts";
export { findPlay } from "./hand_play.ts";
export { jsonStack } from "./wire_json.ts";
export type { PlanLine } from "./engine_v2.ts";
export type { Card } from "./rules/card.ts";
