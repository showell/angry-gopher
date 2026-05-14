// Per-event wire-DSL body emitters. Output is the body only — no
// `<seq>) ` prefix. Callers prepend `seqPrefix(n)` at write time, so
// the seq number is the writer's concern, not the emitter's.
//
// Card tokens use unicode suit glyphs to match Elm's `cardStr`.
// Parsers in both runtimes accept both unicode and ASCII suits;
// emitters consistently use unicode so the wire stream is
// byte-identical across runtimes.

import { type Card, cardToken } from "../core/card.ts";
import type { TimeLoc } from "../core/synthesize_board_paths.ts";

export { cardToken };

export interface Loc { top: number; left: number }
export interface Stack { cards: readonly Card[]; loc: Loc }

export type Side = "left" | "right";


export function seqPrefix(n: number): string {
  return n + ") ";
}


// --- Per-event emitters ----------------------------------------------

export function splitDsl(stack: Stack, cardIndex: number): string {
  return "split " + stackRef(stack) + " @" + cardIndex;
}

export function mergeStackDsl(
  source: Stack,
  target: Stack,
  side: Side,
  boardPath: readonly TimeLoc[] = [],
): string {
  return "merge_stack "
    + stackRef(source)
    + " -> "
    + stackRef(target)
    + " /" + side
    + pathSuffix(boardPath);
}

export function mergeHandDsl(
  handCard: Card,
  target: Stack,
  side: Side,
): string {
  return "merge_hand "
    + cardToken(handCard)
    + " -> "
    + stackRef(target)
    + " /" + side;
}

export function placeHandDsl(handCard: Card, loc: Loc): string {
  return "place_hand "
    + cardToken(handCard)
    + " -> "
    + locStr(loc);
}

export function moveStackDsl(
  stack: Stack,
  newLoc: Loc,
  boardPath: readonly TimeLoc[] = [],
): string {
  return "move_stack "
    + stackRef(stack)
    + " -> "
    + locStr(newLoc)
    + pathSuffix(boardPath);
}

export const completeTurnDsl = "complete_turn";
export const undoDsl = "undo";


// --- Shared internals ------------------------------------------------

function stackRef(s: Stack): string {
  return "[" + s.cards.map(cardToken).join(" ") + "] at " + locStr(s.loc);
}

function locStr(loc: Loc): string {
  // Note: action-log convention is (left,top) — the inverse of the
  // `at (top, left):` board-block convention. Both formats are
  // pinned by the Elm source we mirror (Lib.GameEvent.elm).
  return "(" + loc.left + "," + loc.top + ")";
}

function pathSuffix(path: readonly TimeLoc[]): string {
  if (path.length === 0) return "";
  const samples = path
    .map(p => "(" + p.left + "," + p.top + "@" + p.tMs + ")")
    .join("");
  return " :: path " + samples;
}

