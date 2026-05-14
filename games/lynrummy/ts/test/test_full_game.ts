// test_full_game.ts — automated invariant check over the full-game loop.
//
// The loop asserts these invariants permanently (throws on violation;
// see the don't-paper-over rule in claude memory):
//
//   - every applyPlay → clean board (every stack length-3+ legal)
//   - simulateFullTurn outcome === "hand_empty" iff hand is empty
//   - hand-tracking arithmetic: handBefore - played === handAfter
//   - card conservation across the game
//
// This test runs the agent through several seeds. If any invariant
// fires, the throw exits with a non-zero status and the test fails
// loud. Catches regressions in the BFS pipeline, the agent loop, or
// downstream pieces that touch the simulated state.

import type { Card } from "../core/card.ts";
import { playFullGame } from "../full_game/full_game.ts";
import {
  openingBoardPositioned,
  remainingCards,
  mulberry32,
  shuffle,
} from "../baseline_deal.ts";

const HAND_SIZE = 15;
const NUM_PLAYERS = 2;

function main(): void {
  const seeds = [42, 43, 44, 100, 200, 300];
  let passed = 0;
  let failed = 0;
  const failures: string[] = [];

  for (const seed of seeds) {
    const rand = mulberry32(seed);
    const remaining = shuffle(remainingCards(), rand);
    const hands: readonly (readonly Card[])[] = [
      remaining.slice(0, HAND_SIZE),
      remaining.slice(HAND_SIZE, 2 * HAND_SIZE),
    ];
    const deck = remaining.slice(NUM_PLAYERS * HAND_SIZE);
    const board = openingBoardPositioned();

    try {
      const t0 = Date.now();
      const result = playFullGame(board, hands, deck);
      const ms = Date.now() - t0;
      console.log(`PASS  seed=${seed}  ${result.turns.length} turns, ${result.stoppedReason}  [${ms}ms]`);
      passed++;
    } catch (e) {
      const msg = (e as Error).message;
      console.log(`FAIL  seed=${seed}  ${msg}`);
      failures.push(`seed=${seed}: ${msg}`);
      failed++;
    }
  }

  console.log();
  console.log(`${passed}/${seeds.length} seeds passed`);
  if (failed > 0) process.exit(1);
}

main();
