// inspect_regressions.ts — re-run xcheck #59 and #188 under
// progressively-larger budgets to see whether the regression is
// budget-bounded or fundamental.

import * as fs from "node:fs";
import { findPlay } from "../src/hand_play.ts";

const XCHECK = "/home/steve/showell_repos/angry-gopher/games/lynrummy/python/captures/xcheck_full.jsonl";

const lines = fs.readFileSync(XCHECK, "utf8").split("\n").filter(l => l.trim().length > 0);

const targets = [59, 188];
const budgets = [5000, 20000, 50000, 200000, 500000, 2000000];

for (const t of targets) {
  const e = JSON.parse(lines[t - 1]!);
  const hand = e.hand.map((c: number[]) => [c[0]!, c[1]!, c[2]!] as const);
  const board = e.board.map((s: number[][]) => s.map((c: number[]) => [c[0]!, c[1]!, c[2]!] as const));
  console.log(`\n=== xcheck capture #${t}  (py_steps had ${e.py_steps?.length ?? 0} steps) ===`);
  for (const budget of budgets) {
    const t0 = process.hrtime();
    const result = findPlay(hand, board, { maxStates: budget });
    const dt = process.hrtime(t0);
    const ms = dt[0] * 1000 + dt[1] / 1e6;
    if (result === null) {
      console.log(`  budget=${String(budget).padStart(7)}  STUCK  (${ms.toFixed(0)}ms)`);
    } else {
      console.log(`  budget=${String(budget).padStart(7)}  found ${result.plan.length}-step plan  (${ms.toFixed(0)}ms)`);
    }
  }
}
