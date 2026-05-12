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

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel } from "../src/rules/card.ts";
import { playFullGame } from "../lib/full_game.ts";

const HAND_SIZE = 15;
const NUM_PLAYERS = 2;
const STOP_AT_DECK = 10;

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function boardLocFor(row: number): { top: number; left: number } {
  const col = (row * 3 + 1) % 5;
  return { top: 20 + row * 60, left: 40 + col * 30 };
}

function makeOpeningBoard(): readonly { cards: readonly Card[]; loc: { top: number; left: number } }[] {
  return BOARD_LABELS.map((stack, row) => ({
    cards: stack.map(parseCardLabel),
    loc: boardLocFor(row),
  }));
}

function remainingCards(): Card[] {
  const onBoard = new Set<string>();
  for (const stack of BOARD_LABELS)
    for (const lbl of stack) {
      const c = parseCardLabel(lbl);
      onBoard.add(`${c[0]},${c[1]},${c[2]}`);
    }
  const out: Card[] = [];
  for (let suit = 0; suit < 4; suit++)
    for (let v = 1; v <= 13; v++)
      for (const deck of [0, 1] as const) {
        const c: Card = [v, suit, deck] as const;
        if (!onBoard.has(`${c[0]},${c[1]},${c[2]}`)) out.push(c);
      }
  if (out.length !== 81) throw new Error(`expected 81 remaining; got ${out.length}`);
  return out;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle<T>(arr: readonly T[], rand: () => number): T[] {
  const out = [...arr];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j]!, out[i]!];
  }
  return out;
}

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
    const board = makeOpeningBoard();

    try {
      const t0 = Date.now();
      const result = playFullGame(board, hands, deck, { stopAtDeck: STOP_AT_DECK });
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
