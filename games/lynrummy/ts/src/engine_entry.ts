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

/**
 * Board-shaped entry point. Each board stack is a list of cards
 * (Card tuples). Partitions stacks into helper (complete groups:
 * run / rb / set) vs trouble (everything else), then delegates to
 * `solveStateWithDescs`. Mirrors `Game.Agent.Bfs.solveBoard` in
 * Elm — same partition, same surface.
 *
 * Returns the SHORTEST plan (PlanLine[]) found within the engine's
 * default budget, or null if no plan exists / budget exhausted.
 */
export function solveBoard(
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

// Re-exports — useful if the JS glue needs lower-level access later
// (e.g., for hand_play / findPlay in Phase 2).
export { solveStateWithDescs } from "./engine_v2.ts";
export { findPlay } from "./hand_play.ts";
export type { PlanLine } from "./engine_v2.ts";
export type { Card } from "./rules/card.ts";
