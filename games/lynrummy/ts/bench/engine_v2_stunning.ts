// Test engine_v2 on STUNNING_PUZZLE (state D).
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { solveTurn } from "../src/engine_v2.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

function p(label: string): Card {
  let s = label, deck = 0;
  if (s.endsWith("'")) { deck = 1; s = s.slice(0, -1); }
  return [RANKS.indexOf(s[0]!) + 1, SUITS.indexOf(s[1]!), deck] as const;
}
const P = (...ls: string[]) => ls.map(p);

const raw: RawBuckets = {
  helper: [
    P("3C","4C'","5C'"),
    P("3D","4C","5H","6S","7D'"),
    P("7S","7D","7C","7H"),
    P("KH","AC","2H'"),
    P("KS","AD'","2C","3D'"),
    P("TD","JD","QD","KD"),
  ],
  trouble: [[p("AC'")], [p("AD")], P("AS","2S")],
  growing: [],
  complete: [],
};

const t0 = process.hrtime();
const plan = solveTurn(classifyBuckets(raw), { maxDepth: 12 });
const ms = process.hrtime(t0)[0]*1000 + process.hrtime(t0)[1]/1e6;

console.log(`wall: ${ms.toFixed(0)}ms`);
console.log(`Result: ${plan === null ? "STUCK" : plan.length + "-step plan"}`);
if (plan) for (let i = 0; i < plan.length; i++) console.log(`  ${i+1}. ${plan[i]!.line}`);
