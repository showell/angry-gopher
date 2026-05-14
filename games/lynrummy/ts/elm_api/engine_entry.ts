// engine_entry.ts — browser-bundle entry point for the TS engine.
//
// Re-exports a tight surface for esbuild → IIFE bundling so the Elm
// puzzles UI can call the canonical solver via Elm ports + JS glue.
// Internals stay camelCase / typed; the JS glue handles snake_case
// translation at the wire boundary.

import type { Card } from "../core/card.ts";
import { solveBoard as bfsSolveBoard, type PlanLine } from "../bfs/engine_v2.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { applyLocally } from "../game_events/primitives.ts";
import { expandVerb } from "../step/verbs.ts";
import { findLogicalMovesForPlay, formatHint } from "../step/hand_play.ts";
import { primToWire, type WireActionJson } from "./wire_json.ts";

/**
 * Board-shaped entry point. Each board stack is a list of cards
 * (Card tuples). Partitions stacks into helper (complete groups:
 * run / rb / set) vs trouble (everything else), then delegates to
 * `solveBucketedState`. The Elm-side BFS that this used to
 * mirror has been retired; this is now the canonical solver.
 *
 * Returns the SHORTEST plan (PlanLine[]) found within the engine's
 * default budget, or null if no plan exists / budget exhausted.
 *
 * Used by the puzzles HINT button. Locations aren't needed because
 * hint output is text-only — no primitives to lay out.
 */
function solveBoard(
  board: readonly (readonly Card[])[],
): readonly PlanLine[] | null {
  const result = bfsSolveBoard(board);
  return result === null ? null : result.plan;
}

/**
 * Agent-play entry point. Like `solveBoard` but threads geometry
 * through the verb expansion so callers get back per-move
 * primitive batches in Elm-wire JSON shape.
 *
 * Each batch is `{ line, wire_actions }` where `line` is the
 * canonical DSL string for one logical move and `wire_actions` is
 * the primitive sequence (in `Lib.WireAction` JSON shape) that
 * realizes it on the live board. The Elm side caches batches in
 * `agentProgram` and consumes one per click — same per-move-step
 * walking semantics as the legacy Elm-BFS path.
 *
 * Each `BoardStack` carries `{cards, loc}` matching `geometry.ts`.
 * Locations are required because verb expansion does geometry-
 * aware planning (interior splits relocate, end-splits pre-flight,
 * pushes find open locs, etc.).
 */
function agentPlay(
  board: readonly BoardStack[],
): readonly { line: string; wire_actions: readonly WireActionJson[] }[] | null {
  const cardLists = board.map(s => s.cards);
  const result = bfsSolveBoard(cardLists);
  if (result === null) return null;

  // Thread sim forward across moves. Each desc expands against the
  // current sim, then the resulting primitives advance sim before
  // the next desc expands.
  let sim: readonly BoardStack[] = board;
  const out: { line: string; wire_actions: WireActionJson[] }[] = [];
  for (const planLine of result.plan) {
    const prims = expandVerb(planLine.move, sim, new Set());
    const wireActions: WireActionJson[] = [];
    for (const p of prims) {
      wireActions.push(primToWire(p, sim));
      sim = applyLocally(sim, p);
    }
    out.push({ line: planLine.line, wire_actions: wireActions });
  }
  return out;
}

/**
 * Full-game hint entry point. Given the active player's hand and
 * the live board, return the rendered hint as a flat list of step
 * strings: `["place [<cards>] from hand", "<plan-line>", ...]`,
 * or `[]` if no playable hand card was found.
 *
 * Wraps `findLogicalMovesForPlay` (hand-aware outer loop — triple-in-hand →
 * pair projections → singleton projections → shortest plan) and
 * `formatHint` (renderer). The Elm UI displays `lines` verbatim
 * in the status bar; refining hint phrasing belongs in
 * `hand_play.ts:formatHint`, not here.
 */
export function gameHintLines(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): readonly string[] {
  return formatHint(findLogicalMovesForPlay(hand, board));
}

// --- Elm-facing wrappers ---------------------------------------------------
//
// These are intentional one-liners. Their job is twofold:
//   (a) Signal at the call site (engine_glue.js → LynRummyEngine.elm*)
//       that "this is Elm-bound — if you change it, rebuild engine.js".
//   (b) Narrow the wide return types to what the Elm decoder actually
//       reads.
//
// Heavy lifting lives in solveBoard / agentPlay above (and gameHintLines,
// which has one direct TS caller in `in_progress/run_hint.ts`). These
// three are private to the module otherwise. Don't grow these wrappers.

export function elmSolveBoard(
  board: readonly (readonly Card[])[],
): readonly { line: string }[] | null {
  const result = solveBoard(board);
  return result === null ? null : result.map(p => ({ line: p.line }));
}

export function elmAgentPlay(
  board: readonly BoardStack[],
): readonly { line: string; wire_actions: readonly WireActionJson[] }[] | null {
  return agentPlay(board);
}

export function elmGameHint(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): readonly string[] {
  return gameHintLines(hand, board);
}

