// bench_outer_shell.ts — Compare outer-shell modes on random hands.
//
// TS port of python/bench_outer_shell.py.
//
// Fixed corpus: 60 random 6-card hands drawn from the 81 cards not on
// the Game 17 opening board (6 helpers, 23 cards), seed 42 — TS-side
// PRNG (mulberry32). The hand selection therefore differs from the
// Python version (Python uses Mersenne Twister); this is intentional.
// Python is being retired; the TS bench has its own gold.
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

import { type Card, type Rank, type Suit, type Deck, parseCardLabel, cardLabel } from "../core/card.ts";
import { isPartialOk } from "../core/card_stack.ts";
import { solveBoard } from "../bfs/index.ts";
import { findPlay, type PlayResult } from "../src/hand_play.ts";

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

// ── Fixed board (Game 17 opening) ────────────────────────────────────

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function makeBoard(): readonly (readonly Card[])[] {
  return BOARD_LABELS.map(stack => stack.map(parseCardLabel));
}

function remainingCards(): Card[] {
  const onBoard = new Set<string>();
  for (const stack of BOARD_LABELS) {
    for (const lbl of stack) {
      const c = parseCardLabel(lbl);
      onBoard.add(`${c.rank},${c.suit},${c.deck}`);
    }
  }
  const out: Card[] = [];
  for (let si = 0; si < 4; si++) {
    for (let vi = 0; vi < 13; vi++) {
      for (const deck of [0, 1] as const) {
        const c: Card = { rank: (vi + 1) as Rank, suit: si as Suit, deck: deck as Deck };
        if (!onBoard.has(`${c.rank},${c.suit},${c.deck}`)) out.push(c);
      }
    }
  }
  if (out.length !== 81) throw new Error(`expected 81 remaining; got ${out.length}`);
  return out;
}

// ── PRNG: mulberry32 (deterministic, seed-driven) ───────────────────

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function sample<T>(rng: () => number, pool: readonly T[], k: number): T[] {
  const arr = pool.slice();
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [arr[i], arr[j]] = [arr[j]!, arr[i]!];
  }
  return arr.slice(0, k);
}

// ── Singleton-only mode ─────────────────────────────────────────────
//
// These return just { result, projections }; timing is the caller's
// responsibility (via timeMinOfN). Keeping the work pure of timing
// makes it easy to wrap in min-of-N without per-call instrumentation.

function projectSingleton(
  board: readonly (readonly Card[])[],
  c: Card,
): PlayResult | null {
  const augmented = [...board, [c]];
  const result = solveBoard(augmented);
  if (result === null) return null;
  const moves = result.plan.map(p => p.move);
  const planLines = result.plan.map(p => p.line);
  const newBoard: readonly (readonly Card[])[] = [
    ...result.finalBuckets.helper.map(s => [...s.cards] as readonly Card[]),
    ...result.finalBuckets.complete.map(s => [...s.cards] as readonly Card[]),
  ];
  return { placements: [c], plan: moves, planLines, newBoard };
}

interface SingletonResult {
  result: PlayResult | null;
  projections: number;
}

function findPlaySingletonsOnly(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): SingletonResult {
  const candidates: PlayResult[] = [];
  for (const c of hand) {
    const r = projectSingleton(board, c);
    if (r !== null) candidates.push(r);
  }
  if (candidates.length === 0) return { result: null, projections: hand.length };
  const result = candidates.reduce((best, cur) =>
    cur.plan.length < best.plan.length ? cur : best,
  );
  return { result, projections: hand.length };
}

// ── Full mode ───────────────────────────────────────────────────────

interface FullResult {
  result: PlayResult | null;
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

function fmtResult(result: PlayResult | null): string {
  if (result === null) return "stuck";
  const placements = result.placements.map(cardLabel).join(" ");
  const n = result.plan.length;
  const kind =
    result.placements.length === 2
      ? "pair"
      : result.placements.length === 3
        ? "triple"
        : "single";
  return `${kind} [${placements}] → ${n}-step plan`;
}

function planLen(r: PlayResult | null): number {
  return r === null ? 999 : r.plan.length;
}

function placementCount(r: PlayResult | null): number {
  return r === null ? 0 : r.placements.length;
}

function outcome(r: PlayResult | null): "stuck" | "triple" | "pair" | "single" {
  if (r === null) return "stuck";
  const n = r.placements.length;
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
  for (let i = 0; i < N_HANDS; i++) hands.push(sample(rng, remaining, HAND_SIZE));
  const board = makeBoard();

  console.log(
    `Game 17 board  ·  ${N_HANDS} hands of ${HAND_SIZE} (benchmark size)  ·  seed=${SEED}`,
  );
  console.log();

  const col = 44;

  // Singleton-only pass — min-of-N per hand.
  console.log("=== singleton-only (no pair/triple) ===");
  const soloTimes: number[] = [];
  const soloResults: (PlayResult | null)[] = [];
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
  const fullResults: (PlayResult | null)[] = [];
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
