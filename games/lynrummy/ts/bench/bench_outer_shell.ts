// bench_outer_shell.ts — Compare outer-shell modes on random hands.
//
// Fixed corpus: 60 random 6-card hands drawn from the 81 cards not on
// the Game 17 opening board (6 helpers, 23 cards), seed 42 — see
// `baseline_deal.ts` for the canonical PRNG + deal.
//
// Two modes compared:
//
//   singleton-only  skip pair/triple steps; project each hand card as a
//                   singleton trouble, pick the shortest BFS plan.
//
//   full            triple-in-hand first (no BFS), then every valid pair
//                   as a 2-partial trouble, then every singleton; pick
//                   shortest plan overall. This is hand_play.findPlay.
//
// Usage:
//   node bench/bench_outer_shell.ts

import { type Card, cardLabel } from "../core/card.ts";
import { isPartialOk } from "../core/card_stack.ts";
import { solveBoard } from "../bfs/engine_v2.ts";
import { findPlay, type LogicalMovesForPlay } from "../step/hand_play.ts";
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
//
// MIN_OF_N = 5 picked to give stable totals at acceptable wall time
// (~15-20s total for the full bench). Increase if the gold's times
// still bounce between runs.
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

// ── Singleton-only mode ─────────────────────────────────────────────
//
// These return just { result, projections }; timing is the caller's
// responsibility (via timeMinOfN). Keeping the work pure of timing
// makes it easy to wrap in min-of-N without per-call instrumentation.

function projectSingleton(
  board: readonly (readonly Card[])[],
  c: Card,
): LogicalMovesForPlay | null {
  const augmented = [...board, [c]];
  const result = solveBoard(augmented);
  if (result === null) return null;
  const moves = result.plan.map(p => p.move);
  const moveLines = result.plan.map(p => p.line);
  return { cardsToPlay: [c], moves, moveLines };
}

interface SingletonResult {
  result: LogicalMovesForPlay | null;
  projections: number;
}

function findPlaySingletonsOnly(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): SingletonResult {
  const candidates: LogicalMovesForPlay[] = [];
  for (const c of hand) {
    const r = projectSingleton(board, c);
    if (r !== null) candidates.push(r);
  }
  if (candidates.length === 0) return { result: null, projections: hand.length };
  const result = candidates.reduce((best, cur) =>
    cur.moves.length < best.moves.length ? cur : best,
  );
  return { result, projections: hand.length };
}

// ── Full mode ───────────────────────────────────────────────────────

interface FullResult {
  result: LogicalMovesForPlay | null;
  projections: number;
}

function findPlayFull(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): FullResult {
  const result = findPlay(hand, board);
  // Rough projection count for display: valid pairs + singletons.
  let nPairs = 0;
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      if (isPartialOk([hand[i]!, hand[j]!])) nPairs++;
    }
  }
  return { result, projections: nPairs + hand.length };
}

// ── Formatting ──────────────────────────────────────────────────────

function fmtResult(result: LogicalMovesForPlay | null): string {
  if (result === null) return "stuck";
  const labels = result.cardsToPlay.map(cardLabel).join(" ");
  const n = result.moves.length;
  const kind =
    result.cardsToPlay.length === 2
      ? "pair"
      : result.cardsToPlay.length === 3
        ? "triple"
        : "single";
  return `${kind} [${labels}] → ${n}-step plan`;
}

function planLen(r: LogicalMovesForPlay | null): number {
  return r === null ? 999 : r.moves.length;
}

function placementCount(r: LogicalMovesForPlay | null): number {
  return r === null ? 0 : r.cardsToPlay.length;
}

function outcome(r: LogicalMovesForPlay | null): "stuck" | "triple" | "pair" | "single" {
  if (r === null) return "stuck";
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

// ── Main ────────────────────────────────────────────────────────────

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

  // Singleton-only pass — min-of-N per hand.
  console.log("=== singleton-only (no pair/triple) ===");
  const soloTimes: number[] = [];
  const soloResults: (LogicalMovesForPlay | null)[] = [];
  for (let i = 0; i < hands.length; i++) {
    const { result: solo, bestMs } = timeMinOfN(() => findPlaySingletonsOnly(hands[i]!, board));
    soloTimes.push(bestMs);
    soloResults.push(solo.result);
    const desc = pad(fmtResult(solo.result), col);
    console.log(`  hand ${String(i + 1).padStart(2, " ")}  ${desc}  ${fmtMs(bestMs)}ms  (${solo.projections} projections)`);
  }
  const soloTotal = soloTimes.reduce((a, b) => a + b, 0);
  const soloStuck = soloResults.filter(r => r === null).length;
  console.log(`  ── total ${soloTotal.toFixed(0)}ms  ·  stuck ${soloStuck}/${N_HANDS}\n`);

  // Full pass — min-of-N per hand.
  console.log("=== full (triple-in-hand + pair-BFS + singleton) ===");
  const fullTimes: number[] = [];
  const fullResults: (LogicalMovesForPlay | null)[] = [];
  for (let i = 0; i < hands.length; i++) {
    const { result: full, bestMs } = timeMinOfN(() => findPlayFull(hands[i]!, board));
    fullTimes.push(bestMs);
    fullResults.push(full.result);
    const desc = pad(fmtResult(full.result), col);
    console.log(`  hand ${String(i + 1).padStart(2, " ")}  ${desc}  ${fmtMs(bestMs)}ms  (~${full.projections} projections)`);
  }
  const fullTotal = fullTimes.reduce((a, b) => a + b, 0);
  const fullStuck = fullResults.filter(r => r === null).length;
  console.log(`  ── total ${fullTotal.toFixed(0)}ms  ·  stuck ${fullStuck}/${N_HANDS}\n`);

  // Per-hand comparison.
  let betterPlan = 0,
    samePlan = 0,
    worsePlan = 0,
    morePlacements = 0;
  for (let i = 0; i < N_HANDS; i++) {
    const sp = planLen(soloResults[i]!);
    const fp = planLen(fullResults[i]!);
    const sc = placementCount(soloResults[i]!);
    const fc = placementCount(fullResults[i]!);
    if (fp < sp) betterPlan++;
    else if (fp === sp) samePlan++;
    else worsePlan++;
    if (fc > sc) morePlacements++;
  }

  const counts = { triple: 0, pair: 0, single: 0, stuck: 0 };
  for (const r of fullResults) counts[outcome(r)]++;

  const ratio = fullTotal / Math.max(soloTotal, 0.001);
  console.log("=== summary ===");
  console.log(`  singleton-only  ${soloTotal.toFixed(0).padStart(7, " ")}ms total  stuck ${soloStuck}/${N_HANDS}`);
  console.log(`  full            ${fullTotal.toFixed(0).padStart(7, " ")}ms total  stuck ${fullStuck}/${N_HANDS}`);
  const ratioLine = `  wall ratio (full/solo): ${ratio.toFixed(2)}x`;
  if (ratio > 1) {
    console.log(`${ratioLine}  (full is ${((ratio - 1) * 100).toFixed(0)}% slower in wall time)`);
  } else {
    console.log(`${ratioLine}  (full is ${((1 - ratio) * 100).toFixed(0)}% faster in wall time)`);
  }
  console.log(
    `  plan improvement: better=${betterPlan}  same=${samePlan}  worse=${worsePlan}  more-placements=${morePlacements}  (out of ${N_HANDS} hands)`,
  );
  console.log(
    `  outcome coverage (full): triple=${counts.triple}  pair=${counts.pair}  single=${counts.single}  stuck=${counts.stuck}`,
  );
}

main();
