// baseline_deal.ts — the canonical Game 17 fixed deal: opening board,
// remaining 81 cards, plus the deterministic shuffle the drivers use to
// pick reproducible hands from those 81.
//
// Consumed by `generate_game.ts` (full self-play transcript), the bench
// suite (`bench/bench_outer_shell.ts`), and the full-game tests
// (`test/test_full_game.ts`). All three need the same opening board and
// the same deterministic PRNG so seeds reproduce across drivers.

import type { Card, Rank, Suit, Deck } from "./core/card.ts";
import { parseCardLabel } from "./core/card.ts";
import type { BoardStack } from "./geometry/geometry.ts";

// Locations match dealer.go's initial-board layout
// (`top = 20 + row*60; col = (row*3 + 1) % 5; left = 40 + col*30`) so
// the transcript writer's positioned output matches what Elm renders
// on a fresh-replay bootstrap.
const BOARD_LABELS: readonly (readonly string[])[] = [
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

/** The opening board as positioned stacks (with locs). For drivers
 *  that need to render or write transcripts. */
export function openingBoardPositioned(): readonly BoardStack[] {
  return BOARD_LABELS.map((stack, row) => ({
    cards: stack.map(parseCardLabel),
    loc: boardLocFor(row),
  }));
}

/** The opening board as bare card lists (no locs). For drivers that
 *  only need to feed the solver (e.g., the bench). */
export function openingBoardCardLists(): readonly (readonly Card[])[] {
  return BOARD_LABELS.map(stack => stack.map(parseCardLabel));
}

/** The 81 cards that are NOT on the opening board. Cross-product of
 *  4 suits × 13 ranks × 2 decks minus the 23 dealt to the board. */
export function remainingCards(): Card[] {
  const onBoard = new Set<string>();
  for (const stack of BOARD_LABELS) {
    for (const lbl of stack) {
      const c = parseCardLabel(lbl);
      onBoard.add(`${c.rank},${c.suit},${c.deck}`);
    }
  }
  const out: Card[] = [];
  for (let suit = 0; suit < 4; suit++) {
    for (let v = 1; v <= 13; v++) {
      for (const deck of [0, 1] as const) {
        const c: Card = { rank: v as Rank, suit: suit as Suit, deck: deck as Deck };
        if (!onBoard.has(`${c.rank},${c.suit},${c.deck}`)) out.push(c);
      }
    }
  }
  if (out.length !== 81) throw new Error(`expected 81 remaining; got ${out.length}`);
  return out;
}

/** mulberry32 — deterministic, seedable, native to JS. The drivers
 *  share this so a given seed reproduces the same shuffle across
 *  generate_game, bench, and the tests. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Fisher-Yates over `rand`. Returns a fresh array; caller's input
 *  is not mutated. */
export function shuffle<T>(arr: readonly T[], rand: () => number): T[] {
  const out = [...arr];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j]!, out[i]!];
  }
  return out;
}
