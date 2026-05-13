// UI stack rendering caps at MAX_JOINED_LEN; runs longer than this stay split.

import type { Card } from "../core/card.ts";
import {
  classifyStack,
  KIND_RUN,
  KIND_RB,
} from "../core/card_stack.ts";
import type { BoardStack } from "../src/geometry.ts";
import type { Primitive } from "../src/primitives.ts";
import { planMergeStackOnBoard } from "../src/verbs.ts";
import type { GroomStep } from "./step_types.ts";

const MAX_JOINED_LEN = 15;

export function tryGroom(
  board: readonly BoardStack[],
): { step: GroomStep; board: readonly BoardStack[] } | null {
  const prims: Primitive[] = [];
  let sim = board;
  while (true) {
    const pair = findOneJoinablePair(sim);
    if (pair === null) break;
    const planned = planMergeStackOnBoard(sim, pair.src, pair.tgt, "left");
    prims.push(...planned.prims);
    sim = planned.sim;
  }
  if (prims.length === 0) return null;
  return { step: { kind: "groom", prims }, board: sim };
}

function findOneJoinablePair(
  board: readonly BoardStack[],
): { src: readonly Card[]; tgt: readonly Card[] } | null {
  for (let i = 0; i < board.length; i++) {
    const ci = classifyStack(board[i]!.cards);
    if (ci === null) continue;
    if (ci.kind !== KIND_RUN && ci.kind !== KIND_RB) continue;
    for (let j = 0; j < board.length; j++) {
      if (j === i) continue;
      const cj = classifyStack(board[j]!.cards);
      if (cj === null) continue;
      if (cj.kind !== ci.kind) continue;
      if (ci.n + cj.n > MAX_JOINED_LEN) continue;
      const concat = [...board[i]!.cards, ...board[j]!.cards];
      const joined = classifyStack(concat);
      if (joined === null || joined.kind !== ci.kind) continue;
      return { src: board[i]!.cards, tgt: board[j]!.cards };
    }
  }
  return null;
}
