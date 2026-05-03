// What moves does the enumerator yield at the post-steal-3S state?
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { enumerateMoves, enumerateFocused, initialLineage } from "../src/enumerator.ts";
import { describe } from "../src/move.ts";
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
const buckets = classifyBuckets(raw);

const allMoves: string[] = [];
for (const [desc] of enumerateMoves(buckets)) allMoves.push(describe(desc));

const lineage = initialLineage(buckets.trouble, buckets.growing);
console.log(`focus (lineage[0]) = ${JSON.stringify(lineage[0]?.map(c => RANKS[c[0]-1] + SUITS[c[1]] + (c[2] ? "'" : "")))}`);
const focusedMoves: string[] = [];
for (const [desc] of enumerateFocused({ buckets, lineage })) focusedMoves.push(describe(desc));

console.log(`\nenumerateMoves (no focus filter): ${allMoves.length} moves`);
console.log(`enumerateFocused (focus on):       ${focusedMoves.length} moves\n`);
console.log(`Focus-passing moves:`);
for (const m of focusedMoves) console.log(`  ${m}`);
console.log(`\nMoves filtered out by focus rule:`);
for (const m of allMoves) if (!focusedMoves.includes(m)) console.log(`  ${m}`);
