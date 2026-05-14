// wire_action_parser.ts — parse one LIVE action-log DSL line
// (as emitted by Elm's Lib.GameEvent.elm and the matching TS
// wire_action_dsl.ts) into a Primitive.
//
// Shape:
//   5) merge_stack [cards] at (left,top) -> [cards] at (left,top) /right :: path (...)
//
// Decorators stripped before structural parsing: seq prefix
// `N) `, `at (left,top)` stack-ref decorations, and the
// `:: path (...)` suffix. What's left has scenario-form
// structure BUT keeps the live coordinate convention
// (left,top) — distinct from the conformance walkthrough
// fixtures, which write coordinates as (top,left). We don't
// try to bridge the two here; this parser is for the agent-
// transcript / live wire stream.

import {
  type Primitive, type Side,
  findStackIndex,
  makeSplit, makeMergeStack, makeMergeHand, makeMoveStack, makePlaceHand,
} from "./primitives.ts";
import type { BoardStack, Loc } from "../geometry/geometry.ts";
import { type Card, parseCardLabel } from "../core/card.ts";


export function parseWireActionLine(
  rawLine: string,
  board: readonly BoardStack[],
): Primitive | { action: "complete_turn" } {
  const line = stripDecorators(rawLine);
  return parseStripped(line, board);
}


/** Strip seq prefix, `at (...)` stack-ref decorations, and `::
 *  path (...)` suffix. Returns a scenario-form string ready for
 *  the structural regexes below. */
function stripDecorators(raw: string): string {
  let s = raw.trim();
  s = s.replace(/^\d+\)\s*/, "");
  s = s.replace(/\s*::\s+path\s+\(.*$/, "");
  // `] at (left,top)` → `]` (run-of-mill stack-ref decoration).
  // Repeat: a merge_stack line has two such decorations.
  s = s.replace(/\]\s+at\s+\(-?\d+\s*,\s*-?\d+\)/g, "]");
  return s.trim();
}


function parseStripped(
  line: string,
  board: readonly BoardStack[],
): Primitive | { action: "complete_turn" } {
  if (line === "complete_turn") return { action: "complete_turn" };
  if (line === "undo") {
    throw new Error("undo action not valid in agent transcripts");
  }

  let m = line.match(/^split\s+\[([^\]]+)\]\s*@\s*(-?\d+)$/);
  if (m) {
    const cards = parseCards(m[1]!);
    return makeSplit(board, findStackIndex(board, cards), parseInt(m[2]!, 10));
  }

  m = line.match(/^merge_stack\s+\[([^\]]+)\]\s*->\s*\[([^\]]+)\]\s*\/(left|right)$/);
  if (m) {
    const src = parseCards(m[1]!);
    const tgt = parseCards(m[2]!);
    return makeMergeStack(
      board,
      findStackIndex(board, src),
      findStackIndex(board, tgt),
      m[3]! as Side,
    );
  }

  m = line.match(/^move_stack\s+\[([^\]]+)\]\s*->\s*\((-?\d+)\s*,\s*(-?\d+)\)$/);
  if (m) {
    const cards = parseCards(m[1]!);
    // Live format: (left,top).
    return makeMoveStack(
      board,
      findStackIndex(board, cards),
      { left: parseInt(m[2]!, 10), top: parseInt(m[3]!, 10) },
    );
  }

  m = line.match(/^merge_hand\s+(\S+)\s*->\s*\[([^\]]+)\]\s*\/(left|right)$/);
  if (m) {
    const tgt = parseCards(m[2]!);
    return makeMergeHand(
      board,
      findStackIndex(board, tgt),
      parseCard(m[1]!),
      m[3]! as Side,
    );
  }

  m = line.match(/^place_hand\s+(\S+)\s*->\s*\((-?\d+)\s*,\s*(-?\d+)\)$/);
  if (m) {
    return makePlaceHand(
      parseCard(m[1]!),
      { left: parseInt(m[2]!, 10), top: parseInt(m[3]!, 10) } as Loc,
    );
  }

  throw new Error(`unparseable action line: ${rawForError(line)}`);
}


function rawForError(line: string): string {
  return line.length > 120 ? line.slice(0, 117) + "..." : line;
}


function parseCards(s: string): readonly Card[] {
  return s.trim().split(/\s+/).map(parseCard);
}


function parseCard(s: string): Card {
  // DSL uses trailing `'` for deck-1; internal label uses `:1`.
  const tsLabel = s.endsWith("'") ? s.slice(0, -1) + ":1" : s;
  return parseCardLabel(tsLabel);
}
