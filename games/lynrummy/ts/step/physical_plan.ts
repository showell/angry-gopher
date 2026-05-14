// physical_plan.ts — lowers a LogicalMovesForPlay into the primitive
// sequence that realizes it on a geometric board. This is the
// boundary that adds geometry (open-loc search, crowding-aware
// splits) on top of the BFS-level moves.
//
// Hand cards arrive in two shapes:
//
//   - Single placement (cardsToPlay.length === 1): the card is
//     destined for an existing board stack; expandVerb lifts it to
//     a direct merge_hand inside the verb loop.
//   - Multi-card placement (cardsToPlay.length >= 2): the cards
//     form a fresh stack on the board. Lay them down first via
//     place_hand + merge_hand chain, then run the verb loop with
//     that stack already present.
//
// Every hand card must be consumed by the loop's end; an unconsumed
// card signals a broken plan and throws.

import type { Card } from "../core/card.ts";
import { cardLabel } from "../core/card.ts";
import type { BoardStack } from "../core/geometry.ts";
import { findOpenLoc } from "../core/geometry.ts";
import {
  type Primitive,
  applyLocally,
  makePlaceHand, makeMergeHand,
} from "../game_events/primitives.ts";
import { expandVerb } from "./verbs.ts";
import { cardKey } from "./board.ts";
import type { LogicalMovesForPlay } from "./hand_play.ts";

export function getPrimitivesForLogicalPlay(
  initialBoard: readonly BoardStack[],
  logicalPlay: LogicalMovesForPlay,
): readonly Primitive[] {
  const { cardsToPlay, moves } = logicalPlay;
  let sim: readonly BoardStack[] = initialBoard;
  const pendingHand = new Set(cardsToPlay.map(cardKey));
  const out: Primitive[] = [];

  if (cardsToPlay.length >= 2) {
    // Multi-placement seed: place the first card at a clean loc sized
    // for the eventual stack, then merge the rest onto it rightward.
    const loc = findOpenLoc(sim, cardsToPlay.length);
    const place = makePlaceHand(cardsToPlay[0]!, loc);
    out.push(place);
    sim = applyLocally(sim, place);
    pendingHand.delete(cardKey(cardsToPlay[0]!));
    for (let i = 1; i < cardsToPlay.length; i++) {
      const lastIdx = sim.length - 1;
      const merge = makeMergeHand(sim, lastIdx, cardsToPlay[i]!, "right");
      out.push(merge);
      sim = applyLocally(sim, merge);
      pendingHand.delete(cardKey(cardsToPlay[i]!));
    }
  }

  for (const move of moves) {
    const prims = expandVerb(move, sim, pendingHand);
    for (const p of prims) {
      out.push(p);
      sim = applyLocally(sim, p);
      if (p.action === "merge_hand" || p.action === "place_hand") {
        pendingHand.delete(cardKey(p.handCard));
      }
    }
  }

  if (pendingHand.size > 0) {
    const stranded = [...pendingHand]
      .map(k => cardsToPlay.find((c: Card) => cardKey(c) === k))
      .filter((c): c is Card => c !== undefined)
      .map(cardLabel)
      .join(" ");
    throw new Error(
      `getPrimitivesForLogicalPlay: hand cards [${stranded}] were not consumed `
      + `by the verb sequence; solver returned a plan inconsistent with its `
      + `placements`,
    );
  }

  return out;
}
