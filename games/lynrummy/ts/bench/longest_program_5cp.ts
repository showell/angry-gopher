// longest_program_5cp.ts — extract the longest candidate program
// the BFS explores when running on 5Cp (Game 17 board + trouble
// [5C deck-1]). Mirrors the iterative-deepening discipline but
// tracks the deepest path so we can inspect for false commitments.

import { classifyBuckets, type RawBuckets, stateSig, type FocusedState, troubleCount, isVictory } from "../src/buckets.ts";
import { enumerateFocused, initialLineage } from "../src/enumerator.ts";
import { describe } from "../src/move.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];
const TROUBLE: Card = [5, SUITS.indexOf("C"), 1] as const;  // 5C deck-1

function parseLabel(label: string): Card {
  return [RANKS.indexOf(label[0]!) + 1, SUITS.indexOf(label[1]!), 0] as const;
}

const helper = BOARD_LABELS.map(stk => stk.map(parseLabel));
const raw: RawBuckets = { helper, trouble: [[TROUBLE]], growing: [], complete: [] };
const buckets = classifyBuckets(raw);

const initial: FocusedState = {
  buckets,
  lineage: initialLineage(buckets.trouble, buckets.growing),
};

// Iterative-deepening BFS with program-tracking.
const MAX_TROUBLE_OUTER = 12;
let longestProgram: string[] = [];

for (let cap = 1; cap <= MAX_TROUBLE_OUTER; cap++) {
  const seen = new Set<string>();
  seen.add(stateSig(buckets, initial.lineage));
  type Entry = { state: FocusedState; program: string[] };
  let frontier: Entry[] = [{ state: initial, program: [] }];

  while (frontier.length > 0) {
    const next: Entry[] = [];
    for (const { state, program } of frontier) {
      if (program.length > longestProgram.length) longestProgram = program;
      for (const [desc, newState] of enumerateFocused(state)) {
        const tc = troubleCount(newState.buckets.trouble, newState.buckets.growing);
        if (tc > cap) continue;
        const sig = stateSig(newState.buckets, newState.lineage);
        if (seen.has(sig)) continue;
        seen.add(sig);
        const newProgram = [...program, describe(desc)];
        if (newProgram.length > longestProgram.length) longestProgram = newProgram;
        if (isVictory(newState.buckets.trouble, newState.buckets.growing)) {
          console.log(`VICTORY at cap=${cap}, program length=${newProgram.length}`);
          for (let i = 0; i < newProgram.length; i++) console.log(`  ${i + 1}. ${newProgram[i]}`);
          process.exit(0);
        }
        next.push({ state: newState, program: newProgram });
      }
    }
    frontier = next;
  }
  process.stderr.write(`cap=${cap}: longest so far = ${longestProgram.length} steps\n`);
}

console.log(`\nLongest candidate program (${longestProgram.length} steps):`);
for (let i = 0; i < longestProgram.length; i++) {
  console.log(`  ${i + 1}. ${longestProgram[i]}`);
}
