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
// A regression is flagged when: current_ms > baseline_ms * (1 + tolerance)
//
// Usage:
//   node bench/check_baseline_timing.ts
//   node bench/check_baseline_timing.ts --tolerance=0.10 --runs=20

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../src/rules/card.ts";
import type { RawBuckets } from "../src/buckets.ts";
import { timeSolver } from "./bench_timing.ts";

// TS runs the same corpus ~4× faster than Python — the previous
// 200ms cutoff would leave zero hot scenarios. 50ms keeps 2Cp/2Sp
// in the comparison set; the cheap ones still get measured for
// thermal-trajectory parity but not compared.
const MIN_BASELINE_MS = 50.0;

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
  return [c.value, c.suit, c.origin_deck] as const;
}

function bucketToStacks(bucket: FixtureStack[] | undefined): readonly (readonly Card[])[] {
  if (!bucket) return [];
  return bucket.map(s => s.board_cards.map(bc => asCard(bc.card)));
}

function loadFixtures(p: string): Map<string, Fixture> {
  const raw: Fixture[] = JSON.parse(fs.readFileSync(p, "utf8"));
  const out = new Map<string, Fixture>();
  for (const sc of raw) out.set(sc.name, sc);
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

function parseArgs(argv: string[]): { tolerance: number; runs: number; fixtures: string; baseline: string } {
  let tolerance = 0.10;
  let runs = 20;
  const here = path.dirname(new URL(import.meta.url).pathname);
  let fixtures = path.resolve(here, "../../conformance/fixtures.json");
  let baseline = path.resolve(here, "baseline_board_81_gold.txt");
  for (const a of argv) {
    if (a.startsWith("--tolerance=")) tolerance = parseFloat(a.slice("--tolerance=".length));
    else if (a.startsWith("--runs=")) runs = parseInt(a.slice("--runs=".length), 10);
    else if (a.startsWith("--fixtures=")) fixtures = a.slice("--fixtures=".length);
    else if (a.startsWith("--baseline=")) baseline = a.slice("--baseline=".length);
  }
  return { tolerance, runs, fixtures, baseline };
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  const fixtures = loadFixtures(args.fixtures);
  const baseline = loadBaseline(args.baseline);

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
    const nRuns = isHot ? args.runs : 1;
    const curMs = timeScenario(sc, nRuns);

    if (!isHot) continue;

    const thresholdMs = baseMs * (1 + args.tolerance);
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
