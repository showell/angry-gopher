import type { Card } from "../src/rules/card.ts";
import { findPlay } from "../src/hand_play.ts";
import type { PlayStep } from "./step_types.ts";
import { cardKey } from "./board.ts";

export function tryPlay(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
): { step: PlayStep; board: readonly (readonly Card[])[]; hand: readonly Card[] } | null {
  if (hand.length === 0) return null;

  const play = findPlay(hand, board);
  if (play === null) return null;

  const placedSet = new Set(play.placements.map(cardKey));
  return {
    step: {
      kind: "play",
      placements: [...play.placements],
      planDescs: play.planDescs,
    },
    board: play.newBoard,
    hand: hand.filter(c => !placedSet.has(cardKey(c))),
  };
}
