// One-off: invoke gameHintLines on a captured (hand, board) state
// and print the rendered hint. Used to lock in a known engine
// output for in_progress/*.json captures.

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel } from "../src/rules/card.ts";
import { gameHintLines } from "../src/engine_entry.ts";

const handLabels = [
  "5C'", "2D", "7D'",
];

const boardLabels: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
  ["8D", "9C", "TH"],
  ["QD'", "QS'", "QH"],
  ["6S'", "7S'", "8S'"],
  ["9H'", "TC'", "JH"],
];

function dslLabelToTs(s: string): string {
  return s.endsWith("'") ? s.slice(0, -1) + ":1" : s;
}

const hand: Card[] = handLabels.map(s => parseCardLabel(dslLabelToTs(s)));
const board: Card[][] = boardLabels.map(stack =>
  stack.map(s => parseCardLabel(dslLabelToTs(s))),
);

const lines = gameHintLines(hand, board);
console.log("hint lines:", lines.length);
for (const l of lines) console.log("  " + l);
