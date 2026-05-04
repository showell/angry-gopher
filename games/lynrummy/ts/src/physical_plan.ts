// physical_plan.ts — the agent's gesture pipeline.
//
// One loop. Honest state.
//
//   sim         starts as the real board (no hand cards on it).
//   pendingHand starts as the cards in hand for this play.
//
// For each verb, expandVerb emits the primitives that realize it,
// looking at the current sim and pendingHand to decide hand-to-stack
// vs. board-to-board, small→large direction, and per-primitive
// pre-flight inline. As primitives apply, we update sim and pull cards
// out of pendingHand. That's it — no fake state, no rewrite passes.
//
// Per Steve, 2026-05-04: there's one solver pass and one physical-
// execution pass. The verb-level helpers in `verbs.ts` are where the
// physical-execution decisions live; this module is just the loop.

import type { Card } from "./rules/card.ts";
import { cardLabel } from "./rules/card.ts";
import type { Desc } from "./move.ts";
import type { BoardStack } from "./geometry.ts";
import { findOpenLoc } from "./geometry.ts";
import {
  type Primitive, type PlaceHandPrim, type MergeHandPrim,
  applyLocally,
} from "./primitives.ts";
import { expandVerb } from "./verbs.ts";

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

/** Walk the solver's plan, emitting one primitive sequence.
 *
 *  Hand cards arrive in two shapes:
 *
 *  - Single placement (`hand.length === 1`): the card is destined for
 *    an existing board stack. The verb loop's hand-aware merge in
 *    `expandVerb` lifts it to a direct `merge_hand`. If the loop
 *    finishes without consuming the card, that's a solver bug — fail
 *    hard.
 *
 *  - Multi-card placement (`hand.length >= 2`): the cards form a
 *    fresh stack on the board (a graduate, or the source/target of
 *    an upcoming verb). Lay them down as a single stack first via
 *    `place_hand` + `merge_hand` chain, then run the verb loop with
 *    the placement-stack already on the board.
 */
export function physicalPlan(
  initialBoard: readonly BoardStack[],
  hand: readonly Card[],
  planDescs: readonly Desc[],
): readonly Primitive[] {
  let sim: readonly BoardStack[] = initialBoard;
  const pendingHand = new Set(hand.map(cardKey));
  const out: Primitive[] = [];

  if (hand.length >= 2) {
    // Multi-placement seed: place the first card at a clean loc sized
    // for the eventual stack, then merge the rest onto it rightward.
    const loc = findOpenLoc(sim, hand.length);
    const place: PlaceHandPrim = {
      action: "place_hand", handCard: hand[0]!, loc,
    };
    out.push(place);
    sim = applyLocally(sim, place);
    pendingHand.delete(cardKey(hand[0]!));
    for (let i = 1; i < hand.length; i++) {
      const lastIdx = sim.length - 1;
      const merge: MergeHandPrim = {
        action: "merge_hand",
        targetStack: lastIdx,
        handCard: hand[i]!,
        side: "right",
      };
      out.push(merge);
      sim = applyLocally(sim, merge);
      pendingHand.delete(cardKey(hand[i]!));
    }
  }

  for (const desc of planDescs) {
    const prims = expandVerb(desc, sim, pendingHand);
    for (const p of prims) {
      out.push(p);
      sim = applyLocally(sim, p);
      if (p.action === "merge_hand" || p.action === "place_hand") {
        pendingHand.delete(cardKey(p.handCard));
      }
    }
  }

  // Every hand card must be consumed — by the multi-placement seed or
  // by a hand-aware merge in the verb loop. Anything left means the
  // solver returned placements that no verb references and that we
  // didn't seed — that's broken state, not something to paper over.
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
