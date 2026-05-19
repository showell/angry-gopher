// check_6_card_hands.ts — Regression checker for bench_6_card_hands.
//
// Reads bench_6_card_hands_gold.txt and re-runs the bench (same
// corpus, same timing methodology). Asserts that:
//
//   - per hand: outcome kind (single/pair/triple/stuck) and
//     plan-line count match the gold exactly (structural,
//     deterministic from the BFS)
//   - across all hands: total wall is within TOLERANCE of the gold
//     total
//
// Per-hand timings are NOT gated. min-of-10 still leaves single-
// digit-ms hands too jittery to be a fair trip-wire; even re-
// running the same gold against itself trips fake regressions
// on the smallest hands. The aggregate total smooths that out.
//
// All knobs are hard-coded constants.
//
// Usage:
//   node bench/check_6_card_hands.ts

import * as fs from "node:fs";
import * as path from "node:path";

import { findLogicalMovesForPlay, type LogicalMovesForPlay } from "../plan/hand_play.ts";
import {
  N_HANDS,
  buildCorpus,
  timeMinOfN,
} from "./bench_6_card_hands.ts";

// 30% on the total wall is the regression trip-wire. Total wall
// is much more stable than per-hand min-of-N (noise averages out
// across 100 hands), but a JIT'd runtime can still swing ~20% on
// a loaded machine. 30% sits above ordinary noise while still
// catching a real algorithmic slowdown (a 2× regression trips at
// +100%, well above the threshold).
const TOLERANCE = 0.30;

type Kind = "single" | "pair" | "triple" | "stuck";

interface GoldEntry {
  readonly handIdx: number; // 1-based, as in the gold
  readonly kind: Kind;
  readonly planLines: number; // 0 for stuck
  readonly ms: number;
}

interface Gold {
  readonly entries: readonly GoldEntry[];
  readonly totalWallMs: number;
}

function parseGold(p: string): Gold {
  const text = fs.readFileSync(p, "utf8");
  const entries: GoldEntry[] = [];
  let totalWallMs = -1;
  for (const raw of text.split("\n")) {
    const m = raw.match(
      /^\s*hand\s+(\d+)\s+(single|pair|triple|stuck)(?:\s+\[[^\]]+\]\s+→\s+(\d+)-step plan)?\s+([\d.]+)ms\s*$/,
    );
    if (m) {
      entries.push({
        handIdx: Number.parseInt(m[1]!, 10),
        kind: m[2]! as Kind,
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

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const goldPath = path.resolve(here, "bench_6_card_hands_gold.txt");
  const gold = parseGold(goldPath);
  if (gold.entries.length !== N_HANDS) {
    process.stderr.write(
      `gold has ${gold.entries.length} hands; bench expects ${N_HANDS}. Regenerate the gold.\n`,
    );
    process.exit(1);
  }

  const { hands, board } = buildCorpus();
  const failures: string[] = [];
  let liveTotalMs = 0;

  for (let i = 0; i < N_HANDS; i++) {
    const expected = gold.entries[i]!;
    const { result, bestMs } = timeMinOfN(() => findLogicalMovesForPlay(hands[i]!, board));
    liveTotalMs += bestMs;
    const kind = liveKind(result);
    const lines = liveLines(result);

    if (kind !== expected.kind) {
      const msg = `hand ${i + 1}: outcome ${expected.kind} → ${kind}`;
      console.log(`OUTCOME  ${msg}`);
      failures.push(msg);
      continue;
    }
    if (lines !== expected.planLines) {
      const msg = `hand ${i + 1}: plan-lines ${expected.planLines} → ${lines}`;
      console.log(`PLAN     ${msg}`);
      failures.push(msg);
      continue;
    }
  }

  const thresholdMs = gold.totalWallMs * (1 + TOLERANCE);
  const pct = ((liveTotalMs - gold.totalWallMs) / gold.totalWallMs) * 100;
  console.log(
    `\ntotal wall: ${liveTotalMs.toFixed(0)}ms  (gold ${gold.totalWallMs.toFixed(0)}ms, ${pct >= 0 ? "+" : ""}${pct.toFixed(0)}%)`,
  );
  if (liveTotalMs > thresholdMs) {
    failures.push(`total wall +${pct.toFixed(0)}%  (${gold.totalWallMs.toFixed(0)} → ${liveTotalMs.toFixed(0)}ms; threshold +${(TOLERANCE * 100).toFixed(0)}%)`);
    console.log(`SLOW     total wall exceeds gold * (1 + ${TOLERANCE.toFixed(2)})`);
  }

  console.log(`\n${N_HANDS - failures.filter(f => f.startsWith("hand")).length}/${N_HANDS} hand-structure checks passed`);
  if (failures.length > 0) {
    console.log(`\nFAILURES (${failures.length}):`);
    for (const f of failures) console.log(`  ${f}`);
    process.exit(1);
  }
}

main();
