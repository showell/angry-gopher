// physical_plan.ts — the agent's gesture pipeline. Walks the BFS's
// plan (a sequence of Moves), threading sim + pendingHand state, and
// emits the primitive sequence that realizes the plan on a geometric
// board.
//
// Hand cards arrive in two shapes:
//
//   - Single placement (hand.length === 1): the card is destined for
//     an existing board stack; expandVerb lifts it to a direct
//     merge_hand inside the verb loop.
//   - Multi-card placement (hand.length >= 2): the cards form a fresh
//     stack on the board. Lay them down first via place_hand +
//     merge_hand chain, then run the verb loop with that stack already
//     present.
//
// Every hand card must be consumed by the loop's end; an unconsumed
// card signals a broken plan and throws.

import type { Card } from "../src/rules/card.ts";
import { cardLabel } from "../src/rules/card.ts";
import type { Move } from "../bfs/move.ts";
import type { BoardStack } from "../src/geometry.ts";
import { findOpenLoc } from "../src/geometry.ts";
import {
  type Primitive,
  applyLocally,
  makePlaceHand, makeMergeHand,
} from "../src/primitives.ts";
import { expandVerb } from "../src/verbs.ts";

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

export function physicalPlan(
  initialBoard: readonly BoardStack[],
  hand: readonly Card[],
  plan: readonly Move[],
): readonly Primitive[] {
  let sim: readonly BoardStack[] = initialBoard;
  const pendingHand = new Set(hand.map(cardKey));
  const out: Primitive[] = [];

  if (hand.length >= 2) {
    // Multi-placement seed: place the first card at a clean loc sized
    // for the eventual stack, then merge the rest onto it rightward.
    const loc = findOpenLoc(sim, hand.length);
    const place = makePlaceHand(hand[0]!, loc);
    out.push(place);
    sim = applyLocally(sim, place);
    pendingHand.delete(cardKey(hand[0]!));
    for (let i = 1; i < hand.length; i++) {
      const lastIdx = sim.length - 1;
      const merge = makeMergeHand(sim, lastIdx, hand[i]!, "right");
      out.push(merge);
      sim = applyLocally(sim, merge);
      pendingHand.delete(cardKey(hand[i]!));
    }
  }

  for (const move of plan) {
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
      .map(k => hand.find(c => cardKey(c) === k))
      .filter((c): c is Card => c !== undefined)
      .map(cardLabel)
      .join(" ");
    throw new Error(
      `physicalPlan: hand cards [${stranded}] were not consumed by the `
      + `verb sequence; solver returned a plan inconsistent with its `
      + `placements`,
    );
  }

  return out;
}
