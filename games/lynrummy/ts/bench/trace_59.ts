// trace_59.ts — Run solveStateWithDescs directly on the
// post-`place [5S]` state of capture #59. This skips findPlay
// projection logic and shows whether the underlying BFS can
// solve it without shift.

import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { solveStateWithDescsExt } from "../src/bfs.ts";
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

// Capture #59 board, with 5S placed from hand as a TROUBLE singleton.
const raw: RawBuckets = {
  helper: [
    P("3C", "4C'", "5C'"),
    P("AS", "2S", "3S"),
    P("3D", "4C", "5H", "6S", "7D'"),
    P("7S", "7D", "7C", "7H"),
    P("KH", "AC", "2H'"),
    P("KS", "AD'", "2C", "3D'"),
    P("TD", "JD", "QD", "KD"),
    P("2H", "3H", "4H"),
    P("AC'", "AD", "AH"),
  ],
  trouble: [P("5S")],
  growing: [],
  complete: [],
};

const buckets = classifyBuckets(raw);
const result = solveStateWithDescsExt(buckets, { maxTroubleOuter: 10, maxStates: 500000 });

console.log(`Result: ${result.plan === null ? "STUCK" : result.plan.length + "-step plan"}`);
console.log(`Cap exhaustions (${result.exhaustions.length}):`);
for (const ex of result.exhaustions) {
  const tag = ex.hitMaxStates ? "HIT_MAX" : "natural";
  console.log(`  cap=${String(ex.cap).padStart(2)}  expansions=${String(ex.expansions).padStart(6)}  seen=${String(ex.seenCount).padStart(6)}  ${tag}`);
}
if (result.plan !== null) {
  console.log("\nPlan:");
  for (let i = 0; i < result.plan.length; i++) {
    console.log(`  ${i+1}. ${result.plan[i]!.line}`);
  }
}
