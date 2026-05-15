// dsl/emit.ts — single home for DSL-emission helpers that go with
// dsl/parse.ts. The emitter shape here is the canonical
// human-readable rendering used by conformance scenarios + the Elm
// puzzles wrapper:
//
//   place_hand <card> -> (top,left)
//   merge_hand <card> -> [<stack cards>] /<side>
//   merge_stack [<src cards>] -> [<tgt cards>] /<side>
//   split [<stack cards>]@<index>
//   move_stack [<stack cards>] -> (top,left)
//
// Stacks are addressed by content (card list); deck-2 cards carry
// the universal apostrophe (`5H'`), so a stack's card list is a
// unique identifier in the two-deck setup.

import { type Card, cardLabel } from "../core/card.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import type { Primitive } from "../game_events/primitives.ts";

/** Render one Primitive as its canonical DSL line. The `board`
 *  argument is the live stack-list at the moment of emission —
 *  callers that walk a primitive sequence must apply each
 *  primitive (via applyLocally) before formatting the next. */
export function formatPrimitive(p: Primitive, board: readonly BoardStack[]): string {
  switch (p.action) {
    case "split":
      return `split [${fmtCards(board[p.stackIndex]!.cards)}]@${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack [${fmtCards(board[p.sourceStack]!.cards)}] -> [${fmtCards(board[p.targetStack]!.cards)}] /${p.side}`;
    case "merge_hand":
      return `merge_hand ${cardLabel(p.handCard)} -> [${fmtCards(board[p.targetStack]!.cards)}] /${p.side}`;
    case "move_stack":
      return `move_stack [${fmtCards(board[p.stackIndex]!.cards)}] -> (${p.newLoc.top},${p.newLoc.left})`;
    case "place_hand":
      return `place_hand ${cardLabel(p.handCard)} -> (${p.loc.top},${p.loc.left})`;
  }
}

function fmtCards(cs: readonly Card[]): string {
  return cs.map(cardLabel).join(" ");
}
