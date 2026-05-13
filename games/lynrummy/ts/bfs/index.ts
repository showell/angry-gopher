import type { Card } from "../core/card.ts";
import { classifyStack } from "../core/card_stack.ts";
import { solveBucketedState, type SolveResult } from "./engine_v2.ts";

export type { PlanLine, SolveResult } from "./engine_v2.ts";

/** The BFS entry point most callers want. Takes a board (a list of
 *  stacks), partitions clean stacks (length-3+ legal kinds) into
 *  helpers and the rest into trouble, runs the A* solver, returns
 *  `{plan, finalBuckets}` or `null` if no plan found within the
 *  hard-coded engine budget. */
export function solveBoard(
  board: readonly (readonly Card[])[],
): SolveResult | null {
  const helper: (readonly Card[])[] = [];
  const trouble: (readonly Card[])[] = [];
  for (const stack of board) {
    const ccs = classifyStack(stack);
    if (ccs === null || ccs.n < 3) trouble.push(stack);
    else helper.push(stack);
  }
  return solveBucketedState({ helper, trouble, growing: [], complete: [] });
}
