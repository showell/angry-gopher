// check_baseline_timing.ts — Timing regression checker for the
// 81-card baseline.
//
// Reads the gold file (ts/bench/baseline_board_81_gold.txt) and
// the conformance fixtures (games/lynrummy/conformance/fixtures.json
// — these encode board states only and are language-agnostic).
//
// For each baseline_board_* scenario:
//   - Build the buckets state from the fixture
//   - Run the BFS solver via timeSolver — warmup + min-of-N
//   - Compare against the stored baseline
//
// We measure ALL 81 scenarios so the per-position thermal trajectory
// matches the gold capture. Only scenarios with baseline_ms above
// MIN_BASELINE_MS are COMPARED; the fast ones are measured purely so
// the slow ones see the same CPU state they did at gold-capture time.
//
// A regression is flagged when: current_ms > baseline_ms * (1 + TOLERANCE).
//
// All knobs (TOLERANCE, RUNS, fixture path, baseline path) are
// hard-coded module constants. The bench is meant to be deterministic
// across runs and across machines; runtime variability defeats the
// trip-wire purpose.
//
// Usage:
//   node bench/check_baseline_timing.ts

import * as fs from "node:fs";
import * as path from "node:path";

import { type Card, type Rank, type Suit, type Deck } from "../core/card.ts";
import type { RawBuckets } from "../bfs/buckets.ts";
import { timeSolver } from "./bench_timing.ts";
import { parseConformanceDsl } from "../test/conformance_dsl.ts";

// 50ms is human-scale: any scenario the solver takes longer than
// this on is worth gating against regression. Today no baseline
// scenario is above this (slowest is ~25ms), so the gate is a
// trip-wire for future drift rather than a continuous measurement.
// Cheap scenarios still get measured (n=1) so the per-position
// thermal trajectory matches the gold-capture conditions.
const MIN_BASELINE_MS = 50.0;

// 10% slowdown is the regression trip-wire. Pick this to be loose
// enough that ordinary measurement noise doesn't fire, tight enough
// that a real algorithmic slowdown does.
const TOLERANCE = 0.10;

// Number of timed runs per "hot" scenario. min-of-N. Picked to be
// big enough that GC pauses and JIT warmup wash out, small enough
// that the full 81-scenario sweep stays under a minute.
const RUNS = 20;

interface FixtureCard {
  value: number;
  suit: number;
  origin_deck: number;
}
interface FixtureBoardCard {
  card: FixtureCard;
  state: number;
}
interface FixtureStack {
  board_cards: FixtureBoardCard[];
  loc?: unknown;
}
interface Fixture {
  name: string;
  op: string;
  helper?: FixtureStack[];
  trouble?: FixtureStack[];
  growing?: FixtureStack[];
  complete?: FixtureStack[];
}

function asCard(c: FixtureCard): Card {
  return { rank: c.value as Rank, suit: c.suit as Suit, deck: c.origin_deck as Deck };
}

function bucketToStacks(bucket: FixtureStack[] | undefined): readonly (readonly Card[])[] {
  if (!bucket) return [];
  return bucket.map(s => s.board_cards.map(bc => asCard(bc.card)));
}

function loadFixtures(p: string): Map<string, Fixture> {
  const text = fs.readFileSync(p, "utf8");
  const parsed = parseConformanceDsl(text);
  const out = new Map<string, Fixture>();
  // ParsedScenario's stack shape is structurally identical to Fixture's:
  // both expose `helper/trouble/growing/complete: { board_cards: { card: { value, suit, origin_deck }, state } }[]`.
  for (const sc of parsed) out.set(sc.name, sc as unknown as Fixture);
  return out;
}

interface BaselineEntry {
  ms: number;
  result: string;
}

function loadBaseline(p: string): Map<string, BaselineEntry> {
  const out = new Map<string, BaselineEntry>();
  const text = fs.readFileSync(p, "utf8");
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const parts = line.split(/\s+/);
    if (parts.length < 3) throw new Error(`malformed line: ${JSON.stringify(raw)}`);
    out.set(parts[0]!, { ms: parseFloat(parts[1]!), result: parts[2]! });
  }
  return out;
}

function timeScenario(sc: Fixture, nRuns: number): number {
  const state: RawBuckets = {
    helper: bucketToStacks(sc.helper),
    trouble: bucketToStacks(sc.trouble),
    growing: bucketToStacks(sc.growing),
    complete: bucketToStacks(sc.complete),
  };
  const { bestMs } = timeSolver(state, nRuns);
  return bestMs;
}

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const fixturesPath = path.resolve(here, "../../conformance/scenarios/baseline_board_81.dsl");
  const baselinePath = path.resolve(here, "baseline_board_81_gold.txt");
  const fixtures = loadFixtures(fixturesPath);
  const baseline = loadBaseline(baselinePath);

  const regressions: { sid: string; baseMs: number; curMs: number }[] = [];
  const total = baseline.size;
  const sorted = [...baseline.entries()].sort((a, b) => a[0].localeCompare(b[0]));

  for (let i = 0; i < sorted.length; i++) {
    const [sid, baseInfo] = sorted[i]!;
    const sc = fixtures.get(sid);
    if (!sc) {
      process.stderr.write(`MISSING fixture for ${sid}\n`);
      process.exit(1);
    }
    const baseMs = baseInfo.ms;
    const isHot = baseMs >= MIN_BASELINE_MS;
    const nRuns = isHot ? RUNS : 1;
    const curMs = timeScenario(sc, nRuns);

    if (!isHot) continue;

    const thresholdMs = baseMs * (1 + TOLERANCE);
    const pct = ((curMs - baseMs) / Math.max(baseMs, 0.001)) * 100;
    const isRegression = curMs > thresholdMs;

    process.stdout.write(`[${String(i + 1).padStart(2, " ")}/${total}] ${sid.padEnd(35, " ")} ... `);
    if (isRegression) {
      console.log(`REGRESSION  +${pct.toFixed(0)}%  (${baseMs.toFixed(1)} → ${curMs.toFixed(1)}ms)`);
      regressions.push({ sid, baseMs, curMs });
    } else {
      console.log(`ok  ${curMs.toFixed(1)}ms  (baseline ${baseMs.toFixed(1)}ms)`);
    }
  }

  console.log(`\n${total - regressions.length}/${total} passed`);
  if (regressions.length > 0) {
    console.log(`\nREGRESSIONS (${regressions.length}):`);
    for (const r of regressions) {
      const pct = ((r.curMs - r.baseMs) / Math.max(r.baseMs, 0.001)) * 100;
      console.log(`  ${r.sid}: ${r.baseMs.toFixed(1)}ms → ${r.curMs.toFixed(1)}ms  (+${pct.toFixed(0)}%)`);
    }
    process.exit(1);
  }
}

main();
