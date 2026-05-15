// engine_entry.ts — browser-bundle entry point for the TS engine.
// Re-exports the Elm-facing surface for esbuild → IIFE bundling.

import type { Card } from "../core/card.ts";
import { findLogicalMovesForPlay, formatHint } from "../plan/hand_play.ts";
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

/** Elm-facing wrapper for real-time agent play. Takes board + hand
 *  as canonical DSL strings (same format used by the conformance
 *  corpus) and returns the next play's primitive sequence as a DSL
 *  string — or "" when the agent is stuck (the turn's end signal). */
export function elmAgentStep(boardDsl: string, handDsl: string): string {
  return elmFindPlay(boardDsl, handDsl);
}
