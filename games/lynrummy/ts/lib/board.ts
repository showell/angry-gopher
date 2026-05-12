import type { Card } from "../src/rules/card.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "../src/classified_card_stack.ts";

export function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

export function assertBoardClean(
  board: readonly (readonly Card[])[],
  ctx: string,
): void {
  for (let i = 0; i < board.length; i++) {
    const stack = board[i]!;
    const ccs: ClassifiedCardStack | null = classifyStack(stack);
    if (ccs === null) {
      throw new Error(
        `[board ${ctx}] stack ${i} failed to classify: [${stack.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.n < 3) {
      throw new Error(
        `[board ${ctx}] stack ${i} length ${ccs.n} (${ccs.kind}) — not graduated: [${stack.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.kind !== "run" && ccs.kind !== "rb" && ccs.kind !== "set") {
      throw new Error(
        `[board ${ctx}] stack ${i} kind ${ccs.kind} not a length-3+ legal kind: [${stack.map(cardKey).join(" ")}]`,
      );
    }
  }
}
