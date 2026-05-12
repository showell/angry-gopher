// groom.ts — greedy run-merger. The BFS / play loop happily leaves
// the board with adjacent runs that fit end-to-end (e.g. [9♠ T♠ J♠]
// and [Q♠ K♠ A♠]) but never glues them, because every run is already
// a complete legal stack. Joining them post-hoc opens the board: more
// cards in one stack means more in-place absorbers next turn (a longer
// run accepts peels and yanks at both ends).
//
// Quadratic over board size; at Lyn Rummy scale (≤ ~25 stacks) this
// is cheap. Greedy is fine — any join is locally pure (preserves all
// cards, lengthens a stack), and the iteration restart on each merge
// catches transitive joins.
//
// Cap at MAX_JOINED_LEN (15) because the UI's stack rendering chokes
// on longer stacks. Runs longer than this stay split.

import type { Card } from "../src/rules/card.ts";
import {
  classifyStack,
  KIND_RUN,
  KIND_RB,
} from "../src/classified_card_stack.ts";

const MAX_JOINED_LEN = 15;

/** One greedy run-merge: the contents of the two stacks at the moment
 *  of the merge. The merged stack reads `[...src, ...tgt]` (matches
 *  `merge_stack` with side="left"). Transcript writers materialize
 *  these into wire-level `merge_stack` primitives. */
export interface JoinEvent {
  readonly src: readonly Card[];
  readonly tgt: readonly Card[];
}

export function joinBoardRuns(
  board: readonly (readonly Card[])[],
): { board: readonly (readonly Card[])[]; joins: readonly JoinEvent[] } {
  const cur: (readonly Card[])[] = [...board];
  const joins: JoinEvent[] = [];
  while (true) {
    let merged = false;
    outer: for (let i = 0; i < cur.length; i++) {
      const ci = classifyStack(cur[i]!);
      if (ci === null) continue;
      if (ci.kind !== KIND_RUN && ci.kind !== KIND_RB) continue;
      for (let j = 0; j < cur.length; j++) {
        if (j === i) continue;
        const cj = classifyStack(cur[j]!);
        if (cj === null) continue;
        if (cj.kind !== ci.kind) continue;
        if (ci.n + cj.n > MAX_JOINED_LEN) continue;
        const concat = [...cur[i]!, ...cur[j]!];
        const joined = classifyStack(concat);
        if (joined === null || joined.kind !== ci.kind) continue;
        joins.push({ src: cur[i]!, tgt: cur[j]! });
        cur[i] = concat;
        cur.splice(j, 1);
        merged = true;
        break outer;
      }
    }
    if (!merged) break;
  }
  return { board: cur, joins };
}
