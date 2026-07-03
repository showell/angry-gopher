// engine_entry.ts — browser-bundle entry point for the TS engine.
// Re-exports the Elm-facing surface for esbuild → IIFE bundling.

import type { Card } from "../core/card.ts";
import { findLogicalMovesForPlay, formatHint } from "../plan/hand_play.ts";
import { solveBoard } from "../bfs/engine_v2.ts";
import { elmFindPlay } from "./elm_find_play.ts";

/** Full-game hint entry point. Given the active player's hand and
 *  the live board, returns the rendered hint as a flat list of step
 *  strings (or `[]` if no playable card was found). The Elm UI
 *  displays the lines verbatim in the status bar — phrasing belongs
 *  in `hand_play.ts:formatHint`, not here. */
export function gameHintLines(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): readonly string[] {
  return formatHint(findLogicalMovesForPlay(hand, board));
}

/** Elm-facing wrapper. Same signature; the indirection signals at
 *  the call site (engine_glue.js → LynRummyEngine.elmGameHint) that
 *  "this is Elm-bound — if you change it, rebuild engine.js". */
export function elmGameHint(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): readonly string[] {
  return gameHintLines(hand, board);
}

/** Board-only hint entry point for puzzles. In a puzzle every card
 *  is already on the board — there is no hand to project — so we solve
 *  the board directly and hand back the plan's step lines (engine DSL,
 *  verbatim). The Puzzle UI shows the FIRST line as the hint. Returns
 *  `[]` when the board is already solved or no plan was found. */
export function elmPuzzleHint(
  board: readonly (readonly Card[])[],
): readonly string[] {
  const result = solveBoard(board);
  if (result === null) return [];
  return result.plan.map(p => p.line);
}

/** Elm-facing wrapper for real-time agent play. Takes board + hand
 *  as canonical DSL strings (same format used by the conformance
 *  corpus) and returns the next play's primitive sequence as a DSL
 *  string — or "" when the agent is stuck (the turn's end signal). */
export function elmAgentStep(boardDsl: string, handDsl: string): string {
  return elmFindPlay(boardDsl, handDsl);
}
