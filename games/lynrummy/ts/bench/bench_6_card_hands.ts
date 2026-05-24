// bench_6_card_hands.ts — Per-hand timing of findLogicalMovesForPlay,
// gated against the gold and updating it on success.
//
// Fixed corpus: 100 random 6-card hands drawn from the 81 cards not on
// the Game 17 opening board (6 helpers, 23 cards), seed 42 — see
// `baseline_deal.ts` for the canonical PRNG + deal.
//
// `findLogicalMovesForPlay` is the function the Elm UI hits on every
// solver query. Measure it directly: no in-harness wrappers, no
// re-implementations of the production code path.
//
// Flow:
//   1. Read the gold file (`bench_6_card_hands_gold.txt`).
//   2. For each hand: run benchmarkSingleHand, compare against gold.
//      Fail fast on outcome / plan-line mismatch.
//      Fail fast on per-hand timing > PER_HAND_TOLERANCE worse.
//   3. After all hands: fail fast on total wall > TOTAL_TOLERANCE
//      worse than the gold total.
//   4. RATCHET the gold: overwrite it ONLY when this run is faster, so
//      improvements are captured automatically but the baseline NEVER
//      drifts slower on its own. A slower run within tolerance passes
//      and leaves the gold untouched. Re-baselining to a slower number
//      (e.g. a slower machine) is an explicit decision: delete the gold
//      file and re-run (see Bootstrap).
//
// Bootstrap: if the gold file doesn't exist, skip every comparison
// and just write it out.
//
// Usage:
//   node bench/bench_6_card_hands.ts

import * as fs from "node:fs";
import * as path from "node:path";

import { type Card, cardLabel } from "../core/card.ts";
import { findLogicalMovesForPlay, type LogicalMovesForPlay } from "../plan/hand_play.ts";
import {
  openingBoardCardLists,
  remainingCards,
  mulberry32,
  shuffle,
} from "../baseline_deal.ts";

const N_HANDS = 50;
const HAND_SIZE = 6;
const SEED = 42;

// Per-hand tolerance: 50%. min-of-20 is the most stable per-hand
// statistic on a JIT'd runtime (min approaches the asymptotic floor;
// median and mean are sensitive to GC pauses in the middle of the
// distribution), but small hands still jitter — see MIN_GOLD_MS.
const PER_HAND_TOLERANCE = 0.50;

// Hands below this gold time skip the per-hand timing check. At
// sub-10ms even min-of-20 leaves enough jitter that any tight gate
// generates false positives. The aggregate gate still catches
// regressions in this regime.
const MIN_GOLD_MS = 10.0;

// Aggregate tolerance: 5%. The total wall is the sum of 50 mins;
// noise that survives that aggregation is real.
const TOTAL_TOLERANCE = 0.05;

type Kind = "single" | "pair" | "triple" | "stuck";

interface GoldEntry {
  readonly kind: Kind;
  readonly planLines: number; // 0 for stuck
  readonly ms: number;
}

interface Gold {
  readonly entries: readonly GoldEntry[];
  readonly totalWallMs: number;
}

// Bound to global.gc when node is invoked with --expose-gc, else
// a no-op stub. Forcing GC once per hand keeps prior hands' GC
// pressure from bleeding in, without measuring GC pauses from
// inside this hand's own loop.
const forceGc: () => void =
  typeof (globalThis as { gc?: () => void }).gc === "function"
    ? (globalThis as { gc: () => void }).gc
    : () => {};

function benchmarkSingleHand<T>(work: () => T): { result: T; minMs: number } {
  forceGc();
  work(); // warmup
  let result!: T;
  let minMs = Infinity;
  for (let i = 0; i < 20; i++) {
    const t0 = performance.now();
    result = work();
    const ms = performance.now() - t0;
    if (ms < minMs) minMs = ms;
  }
  return { result, minMs };
}

function buildCorpus(): {
  hands: readonly (readonly Card[])[];
  board: readonly (readonly Card[])[];
} {
  const remaining = remainingCards();
  const rng = mulberry32(SEED);
  const hands: Card[][] = [];
  for (let i = 0; i < N_HANDS; i++) hands.push(shuffle(remaining, rng).slice(0, HAND_SIZE));
  return { hands, board: openingBoardCardLists() };
}

function liveKind(r: LogicalMovesForPlay | null): Kind {
  if (r === null) return "stuck";
  const n = r.cardsToPlay.length;
  if (n >= 3) return "triple";
  if (n === 2) return "pair";
  return "single";
}

function liveLines(r: LogicalMovesForPlay | null): number {
  return r === null ? 0 : r.moves.length;
}

function parseGold(p: string): Gold | null {
  if (!fs.existsSync(p)) return null;
  const text = fs.readFileSync(p, "utf8");
  const entries: GoldEntry[] = [];
  let totalWallMs = -1;
  for (const raw of text.split("\n")) {
    const m = raw.match(
      /^\s*hand\s+\d+\s+(single|pair|triple|stuck)(?:\s+\[[^\]]+\]\s+→\s+(\d+)-step plan)?\s+([\d.]+)ms\s*$/,
    );
    if (m) {
      entries.push({
        kind: m[1]! as Kind,
        planLines: m[2] === undefined ? 0 : Number.parseInt(m[2]!, 10),
        ms: Number.parseFloat(m[3]!),
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
  perHand: readonly { kind: Kind; cards: readonly Card[]; planLines: number; ms: number }[],
  totalWallMs: number,
): void {
  const lines: string[] = [];
  lines.push(`Game 17 board  ·  ${N_HANDS} hands of ${HAND_SIZE} (benchmark size)  ·  seed=${SEED}`);
  lines.push("");
  for (let i = 0; i < perHand.length; i++) {
    lines.push(perHandLine(i + 1, perHand[i]!.kind, perHand[i]!.cards, perHand[i]!.planLines, perHand[i]!.ms));
  }
  lines.push("");
  lines.push("=== summary ===");
  lines.push(`  total wall:  ${totalWallMs.toFixed(0).padStart(5, " ")}ms`);
  const counts = { triple: 0, pair: 0, single: 0, stuck: 0 };
  for (const e of perHand) counts[e.kind]++;
  lines.push(`  outcomes:    triple=${counts.triple}  pair=${counts.pair}  single=${counts.single}  stuck=${counts.stuck}`);
  fs.writeFileSync(p, lines.join("\n") + "\n");
}

function perHandLine(
  handIdx: number,
  kind: Kind,
  cards: readonly Card[],
  planLines: number,
  ms: number,
): string {
  const desc =
    kind === "stuck"
      ? "stuck"
      : `${kind} [${cards.map(cardLabel).join(" ")}] → ${planLines}-step plan`;
  return `  hand ${String(handIdx).padStart(3, " ")}  ${pad(desc, 44)}  ${ms.toFixed(1).padStart(7, " ")}ms`;
}

function pad(s: string, width: number): string {
  return s.length >= width ? s : s + " ".repeat(width - s.length);
}

function fail(msg: string): never {
  console.log(`\nFAIL: ${msg}`);
  process.exit(1);
}

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const goldPath = path.resolve(here, "bench_6_card_hands_gold.txt");
  const gold = parseGold(goldPath);
  if (gold !== null && gold.entries.length !== N_HANDS) {
    fail(`gold has ${gold.entries.length} hands; bench expects ${N_HANDS}. Delete the gold to recapture.`);
  }

  const { hands, board } = buildCorpus();

  console.log(
    `Game 17 board  ·  ${N_HANDS} hands of ${HAND_SIZE} (benchmark size)  ·  seed=${SEED}`,
  );
  console.log();

  const perHand: { kind: Kind; cards: readonly Card[]; planLines: number; ms: number }[] = [];
  let totalMs = 0;

  for (let i = 0; i < N_HANDS; i++) {
    const { result, minMs } = benchmarkSingleHand(() => findLogicalMovesForPlay(hands[i]!, board));
    const kind = liveKind(result);
    const lines = liveLines(result);
    const cards: readonly Card[] = result === null ? [] : result.cardsToPlay;
    totalMs += minMs;
    perHand.push({ kind, cards, planLines: lines, ms: minMs });

    console.log(perHandLine(i + 1, kind, cards, lines, minMs));

    if (gold === null) continue;
    const expected = gold.entries[i]!;
    if (kind !== expected.kind) {
      fail(`hand ${i + 1}: outcome ${expected.kind} → ${kind}`);
    }
    if (lines !== expected.planLines) {
      fail(`hand ${i + 1}: plan-lines ${expected.planLines} → ${lines}`);
    }
    if (expected.ms < MIN_GOLD_MS) continue;
    const ratio = minMs / expected.ms;
    const pct = (ratio - 1) * 100;
    if (ratio > 1 + PER_HAND_TOLERANCE) {
      fail(`hand ${i + 1}: timing +${pct.toFixed(0)}%  (gold ${expected.ms.toFixed(1)} → ${minMs.toFixed(1)}ms; threshold +${(PER_HAND_TOLERANCE * 100).toFixed(0)}%)`);
    }
    if (ratio < 1) {
      console.log(`         ↳ better than gold by ${(-pct).toFixed(0)}%  (gold ${expected.ms.toFixed(1)}ms)`);
    }
  }

  console.log();
  console.log("=== summary ===");
  console.log(`  total wall:  ${totalMs.toFixed(0).padStart(5, " ")}ms`);
  const counts = { triple: 0, pair: 0, single: 0, stuck: 0 };
  for (const e of perHand) counts[e.kind]++;
  console.log(`  outcomes:    triple=${counts.triple}  pair=${counts.pair}  single=${counts.single}  stuck=${counts.stuck}`);

  // Gold updates are a RATCHET: auto-write ONLY when this run is faster
  // (or when bootstrapping a missing gold). A slower run within tolerance
  // PASSES but leaves the gold untouched — we never let the baseline drift
  // slower automatically. To deliberately re-baseline (e.g. a slower
  // machine), delete the gold file and re-run; the bootstrap path recaptures.
  let faster = gold === null;
  if (gold !== null) {
    const ratio = totalMs / gold.totalWallMs;
    const pct = (ratio - 1) * 100;
    if (ratio > 1 + TOTAL_TOLERANCE) {
      fail(`total wall +${pct.toFixed(1)}%  (gold ${gold.totalWallMs.toFixed(0)} → ${totalMs.toFixed(0)}ms; threshold +${(TOTAL_TOLERANCE * 100).toFixed(0)}%)`);
    }
    if (ratio < 1) {
      console.log(`  ↳ total better than gold by ${(-pct).toFixed(1)}%  (gold ${gold.totalWallMs.toFixed(0)}ms) — updating gold`);
      faster = true;
    } else {
      console.log(`  total +${pct.toFixed(1)}% (within tolerance, not faster) — gold unchanged`);
    }
  }

  if (faster) {
    writeGold(goldPath, perHand, totalMs);
    console.log(`\nwrote ${path.basename(goldPath)}`);
  }
}

main();
