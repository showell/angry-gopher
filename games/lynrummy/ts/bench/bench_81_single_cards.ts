// bench_81_single_cards.ts — Per-card timing of solveBoard.
//
// Fixture: the Game 17 opening board (6 helpers, 23 cards). For each
// of the 81 remaining cards in the double deck, project the card as
// a singleton trouble onto the board and run solveBoard.
//
// `solveBoard` is the BFS engine the Elm UI hits on every hint /
// candidate evaluation. Measure it directly: no wrappers.
//
// Flow:
//   1. Read the gold file (`bench_81_single_cards_gold.txt`).
//   2. For each card: run min-of-20, compare against gold.
//      Fail fast on outcome / plan-length mismatch.
//      Fail fast on per-card timing > PER_CARD_TOLERANCE worse.
//   3. After all cards: fail fast on total wall > TOTAL_TOLERANCE
//      worse than the gold total.
//   4. On success, OVERWRITE the gold so improvements are captured
//      automatically.
//
// Bootstrap: if the gold file doesn't exist, skip every comparison
// and just write it out.
//
// Usage:
//   node --expose-gc bench/bench_81_single_cards.ts
//
// (--expose-gc enables the once-per-card forceGc; the bench still
// works without it but with looser variance.)

import * as fs from "node:fs";
import * as path from "node:path";

import {
  type Card,
  type Rank,
  type Suit,
  RANKS,
  SUITS,
  Deck,
  cardLabel,
} from "../core/card.ts";
import { solveBoard } from "../bfs/engine_v2.ts";

const N_ITER = 20;

// Per-card tolerance: 50%. min-of-20 is the most stable per-card
// statistic on a JIT'd runtime (min approaches the asymptotic floor),
// but small cards still jitter — see MIN_GOLD_MS.
const PER_CARD_TOLERANCE = 0.50;

// Cards below this gold time skip the per-card timing check. Sub-10ms
// is timer-noise-dominated even with min-of-20. The aggregate gate
// still catches regressions in this regime.
const MIN_GOLD_MS = 10.0;

// Aggregate tolerance: 5%. The total wall sums 81 mins (~1620
// underlying solveBoard calls); noise that survives that is real.
const TOTAL_TOLERANCE = 0.05;

const BOARD_LABELS: readonly string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

// Bound to global.gc when node is invoked with --expose-gc, else
// a no-op stub. One forceGc per card zeroes cross-card GC
// contamination without measuring GC inside the inner loop.
const forceGc: () => void =
  typeof (globalThis as { gc?: () => void }).gc === "function"
    ? (globalThis as { gc: () => void }).gc
    : () => {};

function parseLabel(label: string): Card {
  const rankIdx = RANKS.indexOf(label[0]!);
  const suitIdx = SUITS.indexOf(label[1]!);
  if (rankIdx < 0 || suitIdx < 0) throw new Error(`bad label ${label}`);
  return { rank: (rankIdx + 1) as Rank, suit: suitIdx as Suit, deck: Deck.One };
}

function helpersAsTuples(): readonly (readonly Card[])[] {
  return BOARD_LABELS.map(stack => stack.map(parseLabel));
}

function cardKey(c: Card): string {
  return `${c.rank},${c.suit},${c.deck}`;
}

function allRemaining(): Card[] {
  const onBoard = new Set<string>();
  for (const stack of BOARD_LABELS) for (const lbl of stack) onBoard.add(cardKey(parseLabel(lbl)));
  const out: Card[] = [];
  for (let si = 0; si < 4; si++) {
    for (let vi = 0; vi < 13; vi++) {
      for (const deck of [Deck.One, Deck.Two] as const) {
        const c: Card = { rank: (vi + 1) as Rank, suit: si as Suit, deck };
        if (!onBoard.has(cardKey(c))) out.push(c);
      }
    }
  }
  return out;
}

interface GoldEntry {
  readonly id: string;
  readonly planLines: number; // 0 for no_plan
  readonly ms: number;
}

interface Gold {
  readonly entries: readonly GoldEntry[];
  readonly totalWallMs: number;
}

function benchmarkSingleCard<T>(work: () => T): { result: T; minMs: number } {
  forceGc();
  work(); // warmup
  let result!: T;
  let minMs = Infinity;
  for (let i = 0; i < N_ITER; i++) {
    const t0 = performance.now();
    result = work();
    const ms = performance.now() - t0;
    if (ms < minMs) minMs = ms;
  }
  return { result, minMs };
}

function perCardLine(id: string, planLines: number, ms: number): string {
  const result = planLines === 0 ? "no_plan" : `${planLines}-step plan`;
  return `  ${pad(id, 6)}  ${pad(result, 13)}  ${ms.toFixed(1).padStart(7)}ms`;
}

function pad(s: string, width: number): string {
  return s.length >= width ? s : s + " ".repeat(width - s.length);
}

function parseGold(p: string): Gold | null {
  if (!fs.existsSync(p)) return null;
  const text = fs.readFileSync(p, "utf8");
  const entries: GoldEntry[] = [];
  let totalWallMs = -1;
  for (const raw of text.split("\n")) {
    const m = raw.match(/^\s*(\S+)\s+(no_plan|(\d+)-step plan)\s+([\d.]+)ms\s*$/);
    if (m) {
      entries.push({
        id: m[1]!,
        planLines: m[3] === undefined ? 0 : Number.parseInt(m[3]!, 10),
        ms: Number.parseFloat(m[4]!),
      });
      continue;
    }
    const total = raw.match(/^\s*total wall:\s+([\d.]+)ms\s*$/);
    if (total) totalWallMs = Number.parseFloat(total[1]!);
  }
  if (totalWallMs < 0) {
    throw new Error(`gold ${p} missing "total wall" line`);
  }
  return { entries, totalWallMs };
}

function writeGold(
  p: string,
  perCard: readonly { id: string; planLines: number; ms: number }[],
  totalWallMs: number,
): void {
  const lines: string[] = [];
  lines.push(`Game 17 board  ·  ${perCard.length} single-card scenarios  ·  min-of-${N_ITER}`);
  lines.push("");
  for (const e of perCard) lines.push(perCardLine(e.id, e.planLines, e.ms));
  lines.push("");
  lines.push("=== summary ===");
  lines.push(`  total wall:  ${totalWallMs.toFixed(0).padStart(5, " ")}ms`);
  const solvable = perCard.filter(e => e.planLines > 0).length;
  lines.push(`  outcomes:    solvable=${solvable}  no_plan=${perCard.length - solvable}`);
  fs.writeFileSync(p, lines.join("\n") + "\n");
}

function fail(msg: string): never {
  console.log(`\nFAIL: ${msg}`);
  process.exit(1);
}

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const goldPath = path.resolve(here, "bench_81_single_cards_gold.txt");
  const gold = parseGold(goldPath);

  const cards = allRemaining();
  if (cards.length !== 81) {
    fail(`expected 81 remaining cards; got ${cards.length}`);
  }
  if (gold !== null && gold.entries.length !== cards.length) {
    fail(`gold has ${gold.entries.length} cards; bench expects ${cards.length}. Delete the gold to recapture.`);
  }

  const board = helpersAsTuples();

  console.log(`Game 17 board  ·  ${cards.length} single-card scenarios  ·  min-of-${N_ITER}`);
  console.log();

  const perCard: { id: string; planLines: number; ms: number }[] = [];
  let totalMs = 0;

  for (let i = 0; i < cards.length; i++) {
    const c = cards[i]!;
    const id = cardLabel(c);
    const cardBoard: readonly (readonly Card[])[] = [...board, [c]];
    const { result, minMs } = benchmarkSingleCard(() => solveBoard(cardBoard));
    const planLines = result === null ? 0 : result.plan.length;
    totalMs += minMs;
    perCard.push({ id, planLines, ms: minMs });

    console.log(perCardLine(id, planLines, minMs));

    if (gold === null) continue;
    const expected = gold.entries[i]!;
    if (id !== expected.id) {
      fail(`card ${i + 1}: id ${expected.id} → ${id}`);
    }
    if (planLines !== expected.planLines) {
      const goldRes = expected.planLines === 0 ? "no_plan" : `${expected.planLines}-step`;
      const liveRes = planLines === 0 ? "no_plan" : `${planLines}-step`;
      fail(`${id}: outcome ${goldRes} → ${liveRes}`);
    }
    if (expected.ms < MIN_GOLD_MS) continue;
    const ratio = minMs / expected.ms;
    const pct = (ratio - 1) * 100;
    if (ratio > 1 + PER_CARD_TOLERANCE) {
      fail(`${id}: timing +${pct.toFixed(0)}%  (gold ${expected.ms.toFixed(1)} → ${minMs.toFixed(1)}ms; threshold +${(PER_CARD_TOLERANCE * 100).toFixed(0)}%)`);
    }
    if (ratio < 1) {
      console.log(`         ↳ better than gold by ${(-pct).toFixed(0)}%  (gold ${expected.ms.toFixed(1)}ms)`);
    }
  }

  console.log();
  console.log("=== summary ===");
  console.log(`  total wall:  ${totalMs.toFixed(0).padStart(5, " ")}ms`);
  const solvable = perCard.filter(e => e.planLines > 0).length;
  console.log(`  outcomes:    solvable=${solvable}  no_plan=${perCard.length - solvable}`);

  if (gold !== null) {
    const ratio = totalMs / gold.totalWallMs;
    const pct = (ratio - 1) * 100;
    if (ratio > 1 + TOTAL_TOLERANCE) {
      fail(`total wall +${pct.toFixed(1)}%  (gold ${gold.totalWallMs.toFixed(0)} → ${totalMs.toFixed(0)}ms; threshold +${(TOTAL_TOLERANCE * 100).toFixed(0)}%)`);
    }
    if (ratio < 1) {
      console.log(`  ↳ total better than gold by ${(-pct).toFixed(1)}%  (gold ${gold.totalWallMs.toFixed(0)}ms)`);
    }
  }

  writeGold(goldPath, perCard, totalMs);
  console.log(`\nwrote ${path.basename(goldPath)}`);
}

main();
