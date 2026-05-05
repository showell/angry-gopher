// wire_json.ts — pure TS-state → Elm-wire JSON encoders.
//
// Browser-safe (no fs / path / node imports). Used by transcript.ts
// (file-writing path) and by engine_entry.ts (browser bundle for
// Elm puzzles agent-play). Extracted 2026-05-04 so the browser
// bundle wouldn't transitively pull in transcript.ts's filesystem
// dependencies.
//
// Shape conventions:
//   - snake_case keys (matches the wire shape Go and Elm both use)
//   - cards as `{value, suit, origin_deck}` objects (not tuples)
//   - stacks as `{board_cards: [{card, state}], loc}` (Elm's
//     `Game.CardStack.encodeCardStack` shape)
//   - state defaults to 0 (FirmlyOnBoard / HandNormal); the agent
//     never freshly-played anything, the recency markers are UI-only

import type { Card } from "./rules/card.ts";
import { cardLabel } from "./rules/card.ts";
import type { BoardStack } from "./geometry.ts";
import type { Primitive } from "./primitives.ts";

export interface JsonCard { value: number; suit: number; origin_deck: number }
export interface JsonBoardCard { card: JsonCard; state: number }
export interface JsonHandCard { card: JsonCard; state: number }
export interface JsonLoc { top: number; left: number }
export interface JsonCardStack { board_cards: JsonBoardCard[]; loc: JsonLoc }
export interface JsonHand { hand_cards: JsonHandCard[] }

export type WireActionJson =
  | { action: "split"; stack: JsonCardStack; card_index: number }
  | { action: "merge_stack"; source: JsonCardStack; target: JsonCardStack; side: "left" | "right" }
  | { action: "merge_hand"; hand_card: JsonCard; target: JsonCardStack; side: "left" | "right" }
  | { action: "place_hand"; hand_card: JsonCard; loc: JsonLoc }
  | { action: "move_stack"; stack: JsonCardStack; new_loc: JsonLoc }
  | { action: "complete_turn" };

export function jsonCard(c: Card): JsonCard {
  return { value: c[0], suit: c[1], origin_deck: c[2] };
}

export function jsonBoardCard(c: Card): JsonBoardCard {
  return { card: jsonCard(c), state: 0 };
}

export function jsonHandCard(c: Card): JsonHandCard {
  return { card: jsonCard(c), state: 0 };
}

export function jsonStack(s: BoardStack): JsonCardStack {
  return {
    board_cards: s.cards.map(jsonBoardCard),
    loc: { top: s.loc.top, left: s.loc.left },
  };
}

/** Render a Primitive in the action-line syntax shared by the
 *  conformance DSL fixtures (`replay_walkthroughs.dsl`,
 *  `verb_to_primitives.dsl`, etc.). The sim-board argument resolves
 *  positional stack references to their card content. */
export function primToDslLine(p: Primitive, sim: readonly BoardStack[]): string {
  const stackCards = (i: number) => sim[i]!.cards.map(cardLabel).join(" ");
  switch (p.action) {
    case "split":
      return `split [${stackCards(p.stackIndex)}]@${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack [${stackCards(p.sourceStack)}]`
        + ` -> [${stackCards(p.targetStack)}] /${p.side}`;
    case "merge_hand":
      return `merge_hand ${cardLabel(p.handCard)}`
        + ` -> [${stackCards(p.targetStack)}] /${p.side}`;
    case "place_hand":
      return `place_hand ${cardLabel(p.handCard)} -> (${p.loc.top},${p.loc.left})`;
    case "move_stack":
      return `move_stack [${stackCards(p.stackIndex)}]`
        + ` -> (${p.newLoc.top},${p.newLoc.left})`;
  }
}

export function primToWire(prim: Primitive, sim: readonly BoardStack[]): WireActionJson {
  switch (prim.action) {
    case "split":
      return {
        action: "split",
        stack: jsonStack(sim[prim.stackIndex]!),
        card_index: prim.cardIndex,
      };
    case "merge_stack":
      return {
        action: "merge_stack",
        source: jsonStack(sim[prim.sourceStack]!),
        target: jsonStack(sim[prim.targetStack]!),
        side: prim.side,
      };
    case "merge_hand":
      return {
        action: "merge_hand",
        hand_card: jsonCard(prim.handCard),
        target: jsonStack(sim[prim.targetStack]!),
        side: prim.side,
      };
    case "place_hand":
      return {
        action: "place_hand",
        hand_card: jsonCard(prim.handCard),
        loc: { top: prim.loc.top, left: prim.loc.left },
      };
    case "move_stack":
      return {
        action: "move_stack",
        stack: jsonStack(sim[prim.stackIndex]!),
        new_loc: { top: prim.newLoc.top, left: prim.newLoc.left },
      };
  }
}
