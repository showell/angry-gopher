// engine_entry.ts — browser-bundle entry point for the TS engine.
// Re-exports the Elm-facing surface for esbuild → IIFE bundling.

import type { Card } from "../core/card.ts";
import { findLogicalMovesForPlay, formatHint } from "../plan/hand_play.ts";
import { solveBoard, PUZZLE_MAX_PLAN_LENGTH } from "../bfs/engine_v2.ts";
import { zigAgentInput, zigPlanPrimitives } from "./zig_agent.ts";

/** Full-game hint entry point. Given the active player's hand and
 *  the live board, returns the rendered hint as a flat list of step
 *  strings (or `[]` if no playable card was found). The Elm UI
 *  displays the lines verbatim in the status bar — phrasing belongs
 *  in `hand_play.ts:formatHint`, not here. */
export function gameHintLines(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
  handLonerPlaced: boolean,
): readonly string[] {
  return formatHint(findLogicalMovesForPlay(hand, board, handLonerPlaced));
}

/** Elm-facing wrapper. Same signature; the indirection signals at
 *  the call site (engine_glue.js → LynRummyEngine.elmGameHint) that
 *  "this is Elm-bound — if you change it, rebuild engine.js". */
export function elmGameHint(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
  handLonerPlaced: boolean,
): readonly string[] {
  return gameHintLines(hand, board, handLonerPlaced);
}

/** Board-only hint entry point for puzzles. In a puzzle every card
 *  is already on the board — there is no hand to project — so we solve
 *  the board directly and hand back the plan's step lines (engine DSL,
 *  verbatim). The Puzzle UI shows the FIRST line as the hint. Returns
 *  `[]` when the board is already solved or no plan was found.
 *
 *  Solves at PUZZLE_MAX_PLAN_LENGTH — deeper than the agent's cap — so
 *  the hardest curated puzzles (6-line) are solvable. The puzzle
 *  conformance (test_curated_puzzles) uses the same constant, so the
 *  depth the UI hints at and the depth the tests prove can't drift. */
export function elmPuzzleHint(
  board: readonly (readonly Card[])[],
): readonly string[] {
  const result = solveBoard(board, PUZZLE_MAX_PLAN_LENGTH);
  if (result === null) return [];
  return result.plan.map(p => p.line);
}

/** Elm-facing wrappers for real-time agent play (Player Two on the
 *  ZIG solver, 2026-07-25). The glue drives the round trip: build the
 *  wasm agentStep input from the request's board/hand DSL, call the
 *  wasm, then lift the returned build recipe into the primitives DSL
 *  — or "" when the agent is stuck (the turn's end signal). */
export function elmZigAgentInput(boardDsl: string, handDsl: string): string {
  return zigAgentInput(boardDsl, handDsl);
}

export function elmZigPlanPrimitives(
  boardDsl: string,
  handDsl: string,
  planText: string,
): string {
  return zigPlanPrimitives(boardDsl, handDsl, planText);
}
