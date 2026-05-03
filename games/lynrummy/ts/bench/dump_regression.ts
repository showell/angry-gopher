// dump_regression.ts — show capture #59 and #188 in full:
// hand, board (kind-tagged), Python's plan-with-shift, and the
// state TS-without-shift gets stuck on.

import * as fs from "node:fs";
import { findPlay } from "../src/hand_play.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { RANKS, SUITS, type Card } from "../src/rules/card.ts";

const XCHECK = "/home/steve/showell_repos/angry-gopher/games/lynrummy/python/captures/xcheck_full.jsonl";

function cardLabel(c: Card): string {
  return RANKS[c[0] - 1] + SUITS[c[1]] + (c[2] ? "'" : "");
}
function stackLabel(stk: readonly Card[]): string {
  return stk.map(cardLabel).join(" ");
}
function tagged(stk: readonly Card[]): string {
  const ccs = classifyStack(stk);
  const kind = ccs ? ccs.kind : "?";
  return `[${stackLabel(stk)}]  (${kind})`;
}

const lines = fs.readFileSync(XCHECK, "utf8").split("\n").filter(l => l.trim().length > 0);

for (const idx of [59, 188]) {
  const e = JSON.parse(lines[idx - 1]!);
  const hand: Card[] = e.hand.map((c: number[]) => [c[0]!, c[1]!, c[2]!]);
  const board: Card[][] = e.board.map((s: number[][]) => s.map((c: number[]) => [c[0]!, c[1]!, c[2]!]));

  console.log(`\n========================================`);
  console.log(`xcheck capture #${idx}  (seed=${e.seed}, turn=${e.turn})`);
  console.log(`========================================`);
  console.log(`Hand (${hand.length}): ${hand.map(cardLabel).join(" ")}`);
  console.log(`Board (${board.length} stacks):`);
  for (const stk of board) {
    console.log(`  ${tagged(stk)}`);
  }
  console.log(`\nPython's plan (with shift, agreed=${e.agreed}):`);
  for (let i = 0; i < e.py_steps.length; i++) {
    console.log(`  ${i + 1}. ${e.py_steps[i]}`);
  }

  // What does TS-without-shift do?
  const result = findPlay(hand, board);
  console.log(`\nTS-without-shift result:`);
  if (result === null) {
    console.log(`  STUCK (find_play returns null)`);
  } else {
    console.log(`  Found ${result.plan.length}-step plan:`);
    for (let i = 0; i < result.plan.length; i++) {
      console.log(`    ${i + 1}. ${result.plan[i]}`);
    }
  }
}
