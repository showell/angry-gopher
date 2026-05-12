// board.ts — board-level leaf utilities: card-key serialization and
// the post-step board-cleanness invariant.

import type { Card } from "../src/rules/card.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "../src/classified_card_stack.ts";

/** Stable serialization of one card to a string key. Used wherever
 *  cards need set / multiset semantics — placement-tracking inside
 *  applyPlay, card-conservation invariants across turns, error
 *  messages that need to identify cards unambiguously. */
export function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

/** Every stack on the board must classify as a legal length-3+ kind
 *  (run / rb / set). The BFS guarantee is that every applyPlay
 *  produces a clean board; if this fires, either the BFS was wrong
 *  or applyPlan diverged from solveStateWithDescs.
 *
 *  Per memory/feedback_dont_paper_over_problems.md: invariants are
 *  permanent (always-on, throw on violation). If this ever fires,
 *  the agent's internal state has diverged from what the rules
 *  guarantee — every downstream symptom (transcript drift, replay
 *  confusion, geometry chaos) cascades from here. */
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
