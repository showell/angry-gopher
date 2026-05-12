// wire_action_dsl.ts — per-event encoders for the live action-log
// DSL, byte-identical to what Elm's Lib.GameEvent.elm emits when
// a human plays. Each function takes only the inputs its event
// needs (earned knowledge at the call site); no dispatch in this
// module.
//
// Shared internals (`seqPrefix`, `stackRef`, `locStr`, `sideStr`,
// `pathSuffix`) live at the bottom and aren't exported — callers
// always go through the per-event API.
//
// Card tokens use unicode suit glyphs to match Elm's `cardStr`.
// Parsers in both runtimes accept both unicode and ASCII suits;
// emitters consistently use unicode so the wire stream is
// byte-identical across runtimes.

import { type Card, SUITS_UNICODE, RANKS } from "./rules/card.ts";

/** Floater (x,y) sample at time `tMs`, in board frame. Matches
 *  Elm's `Lib.TimeLoc.TimeLoc`. Agent transcripts use empty path
 *  lists — replay synthesizes positions JIT. */
export interface TimeLoc { tMs: number; left: number; top: number }

export interface Loc { top: number; left: number }
export interface Stack { cards: readonly Card[]; loc: Loc }

export type Side = "left" | "right";


// --- Per-event emitters ----------------------------------------------

export function splitDsl(
  seq: number,
  stack: Stack,
  cardIndex: number,
): string {
  return seqPrefix(seq) + "split " + stackRef(stack) + " @" + cardIndex;
}

export function mergeStackDsl(
  seq: number,
  source: Stack,
  target: Stack,
  side: Side,
  boardPath: readonly TimeLoc[] = [],
): string {
  return seqPrefix(seq)
    + "merge_stack "
    + stackRef(source)
    + " -> "
    + stackRef(target)
    + " /" + side
    + pathSuffix(boardPath);
}

export function mergeHandDsl(
  seq: number,
  handCard: Card,
  target: Stack,
  side: Side,
): string {
  return seqPrefix(seq)
    + "merge_hand "
    + cardToken(handCard)
    + " -> "
    + stackRef(target)
    + " /" + side;
}

export function placeHandDsl(
  seq: number,
  handCard: Card,
  loc: Loc,
): string {
  return seqPrefix(seq)
    + "place_hand "
    + cardToken(handCard)
    + " -> "
    + locStr(loc);
}

export function moveStackDsl(
  seq: number,
  stack: Stack,
  newLoc: Loc,
  boardPath: readonly TimeLoc[] = [],
): string {
  return seqPrefix(seq)
    + "move_stack "
    + stackRef(stack)
    + " -> "
    + locStr(newLoc)
    + pathSuffix(boardPath);
}

export function completeTurnDsl(seq: number): string {
  return seqPrefix(seq) + "complete_turn";
}

export function undoDsl(seq: number): string {
  return seqPrefix(seq) + "undo";
}


// --- Shared internals ------------------------------------------------

function seqPrefix(n: number): string {
  return n + ") ";
}

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

/** Card token with unicode suit glyph; deck-2 cards get a trailing `'`. */
export function cardToken(c: Card): string {
  const base = RANKS[c[0] - 1]! + SUITS_UNICODE[c[1]]!;
  return c[2] === 0 ? base : `${base}'`;
}
