// capture_subproblem_plan.ts — emit the canonical plan_lines for
// the post-step-2 subproblem of capture #59. With shift enabled,
// solve must succeed; the printed plan_lines are what we put
// into the DSL fixture.

import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { solveStateWithDescs } from "../src/bfs.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

function p(label: string): Card {
  let s = label;
  let deck = 0;
  if (s.endsWith("'")) { deck = 1; s = s.slice(0, -1); }
  const v = RANKS.indexOf(s[0]!);
  const su = SUITS.indexOf(s[1]!);
  return [v + 1, su, deck] as const;
}
function P(...labels: string[]): Card[] { return labels.map(p); }

// State after the first move of the post-step-2 plan
// (steal AH from [AC' AD AH], absorb onto [2H 3H] → graduates).
// Helper [AC' AD AH] is gone; [AC'] and [AD] are spawned trouble.
// [4H 5S] still in growing. COMPLETE [AH 2H 3H] is irrelevant for
// reaching solvability — those cards are simply gone from inventory.
const raw: RawBuckets = {
  helper: [
    P("3C", "4C'", "5C'"),
    P("AS", "2S", "3S"),
    P("3D", "4C", "5H", "6S", "7D'"),
    P("7S", "7D", "7C", "7H"),
    P("KH", "AC", "2H'"),
    P("KS", "AD'", "2C", "3D'"),
    P("TD", "JD", "QD", "KD"),
  ],
  trouble: [P("AC'"), P("AD")],
  growing: [P("4H", "5S")],
  complete: [],
};

const buckets = classifyBuckets(raw);
const plan = solveStateWithDescs(buckets, { maxTroubleOuter: 10, maxStates: 200000 });

if (plan === null) {
  console.log("STUCK (unexpected with shift enabled)");
} else {
  console.log(`Plan (${plan.length} lines):`);
  for (let i = 0; i < plan.length; i++) {
    console.log(`  ${i+1}. ${plan[i]!.line}`);
  }
  console.log("\nDSL plan_lines (drop into expect block):");
  for (const l of plan) {
    // Escape quotes; emit quoted DSL line.
    console.log(`      - "${l.line.replace(/"/g, '\\"')}"`);
  }
}
