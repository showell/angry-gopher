// bench_6_card_hands.ts — Per-hand timing of findLogicalMovesForPlay.
//
// Fixed corpus: 60 random 6-card hands drawn from the 81 cards not on
// the Game 17 opening board (6 helpers, 23 cards), seed 42 — see
// `baseline_deal.ts` for the canonical PRNG + deal.
//
// `findLogicalMovesForPlay` is the function the Elm UI hits on every
// solver query. Measure it directly: no in-harness wrappers, no
// re-implementations of the production code path. Per hand we record
// what the function returned (cards placed + plan length) and how
// long it took (min-of-N).
//
// Usage:
//   node bench/bench_6_card_hands.ts

import { type Card, cardLabel } from "../core/card.ts";
import { findLogicalMovesForPlay, type LogicalMovesForPlay } from "../plan/hand_play.ts";
import {
  openingBoardCardLists,
  remainingCards,
  mulberry32,
  shuffle,
} from "../baseline_deal.ts";

const N_HANDS = 60;
const HAND_SIZE = 6;
const SEED = 42;

// Per-hand min-of-N timing parameters. Single-shot is too noisy
// (individual swings 30-200% on a loaded system); min-of-N with a
// warmup stabilizes the gold so it can serve as a real timing
// trip-wire, not just a snapshot.
const TIMING_WARMUP_RUNS = 1;
const TIMING_MIN_OF_N = 5;

function timeMinOfN<T>(work: () => T): { result: T; bestMs: number } {
  for (let i = 0; i < TIMING_WARMUP_RUNS; i++) work();
  let bestMs = Infinity;
  let result!: T;
  for (let i = 0; i < TIMING_MIN_OF_N; i++) {
    const t0 = performance.now();
    result = work();
    const ms = performance.now() - t0;
    if (ms < bestMs) bestMs = ms;
  }
  return { result, bestMs };
}

function fmtResult(result: LogicalMovesForPlay | null): string {
  if (result === null) return "stuck";
  const labels = result.cardsToPlay.map(cardLabel).join(" ");
  return `${kindLabel(result)} [${labels}] → ${result.moves.length}-step plan`;
}

function kindLabel(r: LogicalMovesForPlay): "single" | "pair" | "triple" {
  const n = r.cardsToPlay.length;
  if (n >= 3) return "triple";
  if (n === 2) return "pair";
  return "single";
}

function pad(s: string, width: number): string {
  return s.length >= width ? s : s + " ".repeat(width - s.length);
}

function fmtMs(ms: number): string {
  return ms.toFixed(1).padStart(7, " ");
}

function main(): void {
  const remaining = remainingCards();
  const rng = mulberry32(SEED);
  const hands: Card[][] = [];
  for (let i = 0; i < N_HANDS; i++) hands.push(shuffle(remaining, rng).slice(0, HAND_SIZE));
  const board = openingBoardCardLists();

  console.log(
    `Game 17 board  ·  ${N_HANDS} hands of ${HAND_SIZE} (benchmark size)  ·  seed=${SEED}`,
  );
  console.log();

  const col = 44;
  const times: number[] = [];
  const results: (LogicalMovesForPlay | null)[] = [];
  for (let i = 0; i < hands.length; i++) {
    const { result, bestMs } = timeMinOfN(() => findLogicalMovesForPlay(hands[i]!, board));
    times.push(bestMs);
    results.push(result);
    const desc = pad(fmtResult(result), col);
    console.log(`  hand ${String(i + 1).padStart(2, " ")}  ${desc}  ${fmtMs(bestMs)}ms`);
  }

  const total = times.reduce((a, b) => a + b, 0);
  const counts = { triple: 0, pair: 0, single: 0, stuck: 0 };
  for (const r of results) {
    if (r === null) counts.stuck++;
    else counts[kindLabel(r)]++;
  }

  console.log();
  console.log("=== summary ===");
  console.log(`  total wall:  ${total.toFixed(0).padStart(5, " ")}ms`);
  console.log(`  outcomes:    triple=${counts.triple}  pair=${counts.pair}  single=${counts.single}  stuck=${counts.stuck}`);
}

main();
