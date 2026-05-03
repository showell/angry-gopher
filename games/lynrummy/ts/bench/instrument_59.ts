// instrument_59.ts — reconstruct the post-line-2 state of capture #59
// and inspect what the enumerator yields with shift disabled.
//
// Specifically: is "steal 3S from [AS 2S 3S], absorb onto [4H 5S]" yielded?

import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import { enumerateFocused, initialLineage } from "../src/enumerator.ts";
import { describe } from "../src/move.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

function p(label: string): Card {
  // "AC", "5S", "AC'" → Card. "'" denotes deck=1.
  let s = label;
  let deck = 0;
  if (s.endsWith("'")) { deck = 1; s = s.slice(0, -1); }
  const v = RANKS.indexOf(s[0]!);
  const su = SUITS.indexOf(s[1]!);
  return [v + 1, su, deck] as const;
}

function P(...labels: string[]): Card[] { return labels.map(p); }

// Post-line-2 state of capture #59 (after `place 5S`, `steal 4H from [2H 3H 4H], absorb onto [5S]`):
const raw: RawBuckets = {
  helper: [
    P("3C", "4C'", "5C'"),
    P("AS", "2S", "3S"),
    P("3D", "4C", "5H", "6S", "7D'"),
    P("7S", "7D", "7C", "7H"),
    P("KH", "AC", "2H'"),
    P("KS", "AD'", "2C", "3D'"),
    P("TD", "JD", "QD", "KD"),
    P("AC'", "AD", "AH"),
  ],
  trouble: [P("2H", "3H")],
  growing: [P("4H", "5S")],
  complete: [],
};

const buckets = classifyBuckets(raw);

console.log("=== Post-line-2 state of capture #59 ===\n");
console.log("HELPERS:");
for (const s of buckets.helper) console.log(`  [${s.cards.map(c => RANKS[c[0]-1] + SUITS[c[1]] + (c[2] ? "'" : "")).join(" ")}]  (${s.kind})`);
console.log("TROUBLE:");
for (const s of buckets.trouble) console.log(`  [${s.cards.map(c => RANKS[c[0]-1] + SUITS[c[1]] + (c[2] ? "'" : "")).join(" ")}]  (${s.kind})`);
console.log("GROWING:");
for (const s of buckets.growing) console.log(`  [${s.cards.map(c => RANKS[c[0]-1] + SUITS[c[1]] + (c[2] ? "'" : "")).join(" ")}]  (${s.kind})`);

console.log("\n--- enumerateMoves (no focus filter) ---");
let n = 0;
let stealHits = 0;
for (const [desc] of enumerateMoves(buckets)) {
  n++;
  const line = describe(desc);
  if (line.includes("[AS 2S 3S]") || line.includes("steal 3S") || line.includes("steal AS")) {
    console.log(`  YIELDED: ${line}`);
    stealHits++;
  }
}
console.log(`\nTotal moves yielded: ${n}`);
console.log(`Steal-from-[AS 2S 3S] moves: ${stealHits}`);

// Now check enumerateFocused (with focus rule). The real BFS lineage
// at post-line-2 is [[4H 5S], [2H 3H]] — the absorb's result is
// pushed to lineage[0] by updateLineage, then spawned [2H 3H] is
// appended. (initialLineage produces trouble-first, which is wrong
// here.)
console.log("\n--- enumerateFocused (focus = [4H 5S], the actual BFS focus) ---");
const lineage = [
  P("4H", "5S") as readonly Card[],   // freshly merged (lineage[0] post-absorb)
  P("2H", "3H") as readonly Card[],   // spawned; appended at end
];
console.log(`lineage = ${JSON.stringify(lineage.map(e => e.map(c => RANKS[c[0]-1] + SUITS[c[1]])))}`);
console.log(`focus (lineage[0]) = ${JSON.stringify(lineage[0]?.map(c => RANKS[c[0]-1] + SUITS[c[1]]))}`);

let nFocused = 0;
let stealFocusedHits = 0;
const focusedMoves: string[] = [];
for (const [desc] of enumerateFocused({ buckets, lineage })) {
  nFocused++;
  const line = describe(desc);
  focusedMoves.push(line);
  if (line.includes("[AS 2S 3S]")) stealFocusedHits++;
}
console.log(`Total focus-passing moves: ${nFocused}`);
console.log(`Steal-from-[AS 2S 3S] (focused): ${stealFocusedHits}`);
console.log(`\nAll focus-passing moves:`);
for (const m of focusedMoves) console.log(`  ${m}`);
