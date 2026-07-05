// One-off: invoke gameHintLines on a captured (hand, board) state
// and print the rendered hint. Used to lock in a known engine
// output for in_progress/*.json captures.

import type { Card } from "../core/card.ts";
import { parseCardLabel } from "../core/card.ts";
import { gameHintLines } from "../elm_api/engine_entry.ts";

// uid 16 (Stephen2), game 2, mid-turn after 15 actions (10 hand cards played:
// T♠' J♥' Q♠ A♠' 5♦' 5♥' 6♠' 2♥' 4♥' 2♠'). Reconstructed from sessions/2/meta
// + replaying actions.dsl. Hand down to 5 cards.
const handLabels = [
  "8H", "4D", "8D", "6C'", "9C'",
];

const boardLabels: string[][] = [
  ["KS", "AS", "2S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H", "5H'"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH", "AS'"],
  ["2C", "3D", "4C", "5H", "6S'"],
  ["5D'", "6S", "7H"],
  ["TS'", "JH'", "QS"],
  ["2H'", "3S", "4H'"],
  ["2S'"],
];

const hand: Card[] = handLabels.map(parseCardLabel);
const board: Card[][] = boardLabels.map(stack => stack.map(parseCardLabel));

// game-2 state: the 2♠ was just laid from hand onto an empty spot.
const lines = gameHintLines(hand, board, true);
console.log("hint lines:", lines.length);
for (const l of lines) console.log("  " + l);
