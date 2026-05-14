import type { Card } from "../core/card.ts";
import { findPlay } from "./hand_play.ts";
import { physicalPlan } from "./physical_plan.ts";
import { applyLocally } from "../game_events/primitives.ts";
import type { BoardStack } from "../core/geometry.ts";
import type { PlayStep } from "./step_types.ts";
import { cardKey } from "./board.ts";

export function tryPlay(
  board: readonly BoardStack[],
  hand: readonly Card[],
): { step: PlayStep; board: readonly BoardStack[]; hand: readonly Card[] } | null {
  if (hand.length === 0) return null;

  const cardLists = board.map(s => s.cards);
  const play = findPlay(hand, cardLists);
  if (play === null) return null;

  const prims = physicalPlan(board, [...play.cardsToPlay], play.moves);
  let sim: readonly BoardStack[] = board;
  for (const p of prims) sim = applyLocally(sim, p);

  const placedSet = new Set(play.cardsToPlay.map(cardKey));
  return {
    step: {
      kind: "play",
      cardsToPlay: [...play.cardsToPlay],
      prims,
    },
    board: sim,
    hand: hand.filter(c => !placedSet.has(cardKey(c))),
  };
}
