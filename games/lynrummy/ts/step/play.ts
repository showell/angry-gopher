import type { Card } from "../core/card.ts";
import { findLogicalMovesForPlay } from "./hand_play.ts";
import { getPrimitivesForLogicalPlay } from "./physical_plan.ts";
import { applyLocally } from "../game_events/primitives.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import type { PrimitivesForPlay } from "./step_types.ts";
import { cardKey } from "./board.ts";

export function findPlayPrimitives(
  board: readonly BoardStack[],
  hand: readonly Card[],
): { step: PrimitivesForPlay; board: readonly BoardStack[]; hand: readonly Card[] } | null {
  if (hand.length === 0) return null;

  const cardLists = board.map(s => s.cards);
  const logicalPlay = findLogicalMovesForPlay(hand, cardLists);
  if (logicalPlay === null) return null;

  const prims = getPrimitivesForLogicalPlay(board, logicalPlay);
  let sim: readonly BoardStack[] = board;
  for (const p of prims) sim = applyLocally(sim, p);

  const placedSet = new Set(logicalPlay.cardsToPlay.map(cardKey));
  return {
    step: {
      kind: "play",
      cardsToPlay: [...logicalPlay.cardsToPlay],
      prims,
    },
    board: sim,
    hand: hand.filter(c => !placedSet.has(cardKey(c))),
  };
}
