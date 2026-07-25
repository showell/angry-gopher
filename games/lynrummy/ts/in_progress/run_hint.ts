// One-off: invoke the TS reference hint on a captured (hand, board) state
// and print the rendered hint. Used to lock in a known engine
// output for in_progress/*.json captures.

import type { Card } from "../core/card.ts";
import { parseCardLabel } from "../core/card.ts";
import { findLogicalMovesForPlay, formatHint } from "../plan/hand_play.ts";

// uid 16 (Stephen2), game 4, mid-turn. Reconstructed from sessions/4/meta
// + replaying actions.dsl (21 actions). Hand down to 3 cards.
// The dirty stack is [5S 6H]: 6H was placed as a loner (action 19), then
// 5S was split off the spade run and merged onto it (actions 20-21).
// So the LAST non-cosmetic move is merge_stack, NOT place_hand.
const handLabels = [
  "6D'", "3C", "KC'",
];

const boardLabels: string[][] = [
  ["JS'", "QS'", "KS", "AS", "2S", "3S", "4S"],
  ["8D", "9C'", "TD", "JC"],
  ["TD'", "JD", "QD", "KD"],
  ["AH'", "2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C"],
  ["4S'", "5H", "6S", "7H", "8S"],
  ["5S", "6H"],
];

const hand: Card[] = handLabels.map(parseCardLabel);
const board: Card[][] = boardLabels.map(stack => stack.map(parseCardLabel));

// game-4 state: last non-cosmetic move was merge_stack (board->board), so
// Elm's lastMoveWasHandLoner would be FALSE. Reproduce the real hint.
const lines = formatHint(findLogicalMovesForPlay(hand, board, false));
console.log("hint lines (loner=false):", lines.length);
for (const l of lines) console.log("  " + l);

console.log("");
const linesLoner = formatHint(findLogicalMovesForPlay(hand, board, true));
console.log("hint lines (loner=true):", linesLoner.length);
for (const l of linesLoner) console.log("  " + l);
