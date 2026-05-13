import type { Card } from "../src/rules/card.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "../bfs/classified_card_stack.ts";
import type { BoardStack } from "../src/geometry.ts";

export function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
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
