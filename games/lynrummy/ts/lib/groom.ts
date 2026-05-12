import type { Card } from "../src/rules/card.ts";
import {
  classifyStack,
  KIND_RUN,
  KIND_RB,
} from "../src/classified_card_stack.ts";
import type { GroomStep, JoinEvent } from "./step_types.ts";

// UI stack rendering caps here; runs longer than this stay split.
const MAX_JOINED_LEN = 15;

export function tryGroom(
  board: readonly (readonly Card[])[],
): { step: GroomStep; board: readonly (readonly Card[])[] } | null {
  const groomed = joinBoardRuns(board);
  if (groomed.joins.length === 0) return null;
  return {
    step: { kind: "groom", joins: groomed.joins },
    board: groomed.board,
  };
}

function joinBoardRuns(
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
