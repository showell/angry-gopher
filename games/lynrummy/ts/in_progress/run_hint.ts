// One-off: invoke gameHintLines on a captured (hand, board) state
// and print the rendered hint. Used to lock in a known engine
// output for in_progress/*.json captures.

import type { Card } from "../core/card.ts";
import { parseCardLabel } from "../core/card.ts";
import { gameHintLines } from "../elm_api/engine_entry.ts";

// uid 16 (Stephen2), game 2, mid-turn after 7 hand cards played.
// Reconstructed from sessions/2/meta + replaying actions.dsl (10 actions).
const handLabels = [
  "2H'", "4H'", "8H", "2S'", "4D", "8D", "6C'", "9C'",
];

const boardLabels: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H", "5H'"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH", "AS'"],
  ["2C", "3D", "4C", "5H", "6S'"],
  ["5D'", "6S", "7H"],
  ["TS'", "JH'", "QS"],
];

const hand: Card[] = handLabels.map(parseCardLabel);
const board: Card[][] = boardLabels.map(stack => stack.map(parseCardLabel));

const lines = gameHintLines(hand, board);
console.log("hint lines:", lines.length);
for (const l of lines) console.log("  " + l);
