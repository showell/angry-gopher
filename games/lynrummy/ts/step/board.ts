import type { Card } from "../core/card.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "../core/card_stack.ts";
import type { BoardStack } from "../src/geometry.ts";

export function cardKey(c: Card): string {
  return `${c.rank},${c.suit},${c.deck}`;
}

export function assertBoardClean(
  board: readonly BoardStack[],
  ctx: string,
): void {
  for (let i = 0; i < board.length; i++) {
    const cards = board[i]!.cards;
    const ccs: ClassifiedCardStack | null = classifyStack(cards);
    if (ccs === null) {
      throw new Error(
        `[board ${ctx}] stack ${i} failed to classify: [${cards.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.n < 3) {
      throw new Error(
        `[board ${ctx}] stack ${i} length ${ccs.n} (${ccs.kind}) — not graduated: [${cards.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.kind !== "run" && ccs.kind !== "rb" && ccs.kind !== "set") {
      throw new Error(
        `[board ${ctx}] stack ${i} kind ${ccs.kind} not a length-3+ legal kind: [${cards.map(cardKey).join(" ")}]`,
      );
    }
  }
}
