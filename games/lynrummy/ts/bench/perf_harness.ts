// perf_harness.ts — load find_play snapshots, benchmark.
//
// Reads a JSONL file of captured `find_play` snapshots and:
//   - lists the slowest cases by recorded total_wall;
//   - re-runs each top-N case --repeats times and reports median wall
//     (independent of network jitter — only exercises the planner).
//
// For deeper profiling: `node --prof bench/perf_harness.ts ...` then
// `node --prof-process` on the log.
//
// NOTE: the original snapshot-capture mechanism was Python-side and
// retired with the Python subtree. Until a TS-side capture lands,
// this harness has no input source; kept against the day it's needed.
//
// Usage:
//   node bench/perf_harness.ts /tmp/perf_snapshots.jsonl
//   node bench/perf_harness.ts snaps.jsonl --top=5 --repeats=3
//   node bench/perf_harness.ts snaps.jsonl --max-states=10000

import * as fs from "node:fs";

import type { Card } from "../src/rules/card.ts";
import { findPlay, type PlayStats } from "../src/hand_play.ts";

interface CapturedProjection {
  kind: "pair" | "singleton";
  cards: number[][];
  wall: number;
  found_plan: boolean;
}

interface CapturedSnapshot {
  hand: number[][];
  board: number[][][];
  projections: CapturedProjection[];
  total_wall: number;
  found_play: boolean;
}

function asCard(c: number[]): Card {
  return [c[0]!, c[1]!, c[2]!] as const;
}

function loadSnapshots(p: string): CapturedSnapshot[] {
  const out: CapturedSnapshot[] = [];
  const text = fs.readFileSync(p, "utf8");
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    out.push(JSON.parse(line));
  }
  return out;
}

function median(xs: readonly number[]): number {
  const a = [...xs].sort((x, y) => x - y);
  const n = a.length;
  if (n === 0) return 0;
  return n % 2 === 1 ? a[(n - 1) >> 1]! : (a[n / 2 - 1]! + a[n / 2]!) / 2;
}

interface Summary {
  capturedWall: number;
  medianWall: number;
  minWall: number;
  maxWall: number;
  handSize: number;
  boardSize: number;
  foundPlay: boolean;
  nProjections: number;
}

function timeOne(rec: CapturedSnapshot, repeats: number, maxStates: number): { walls: number[]; lastStats: PlayStats } {
  const hand = rec.hand.map(asCard);
  const board = rec.board.map(s => s.map(asCard));
  let lastStats: PlayStats = { totalWallMs: 0, projections: [] };
  const walls: number[] = [];
  for (let i = 0; i < repeats; i++) {
    lastStats = { totalWallMs: 0, projections: [] };
    const t0 = performance.now();
    findPlay(hand, board, { maxStates, stats: lastStats });
    walls.push((performance.now() - t0) / 1000); // seconds, to match Python
  }
  return { walls, lastStats };
}

function summarize(rec: CapturedSnapshot, walls: number[], _stats: PlayStats): Summary {
  return {
    capturedWall: rec.total_wall,
    medianWall: median(walls),
    minWall: Math.min(...walls),
    maxWall: Math.max(...walls),
    handSize: rec.hand.length,
    boardSize: rec.board.length,
    foundPlay: rec.found_play,
    nProjections: rec.projections.length,
  };
}

function printSummary(rank: number, s: Summary): void {
  console.log(
    `  #${String(rank).padStart(2, " ")} captured=${s.capturedWall.toFixed(2).padStart(5)}s ` +
      `median=${s.medianWall.toFixed(2).padStart(5)}s ` +
      `min=${s.minWall.toFixed(2).padStart(5)}s ` +
      `max=${s.maxWall.toFixed(2).padStart(5)}s | ` +
      `hand=${String(s.handSize).padStart(2)} ` +
      `board=${String(s.boardSize).padStart(2)} ` +
      `projs=${String(s.nProjections).padStart(2)} ` +
      `${s.foundPlay ? "+plan" : "STUCK"}`,
  );
}

function printProjectionBreakdown(rec: CapturedSnapshot): void {
  console.log("    projections:");
  for (const proj of rec.projections) {
    const cards = proj.cards.map(c => `${c[0]}/${c[1]}/${c[2]}`).join(",");
    const marker = proj.found_plan ? "✓" : "·";
    console.log(`      ${marker} ${proj.kind.padEnd(9)} wall=${proj.wall.toFixed(2)}s cards=[${cards}]`);
  }
}

interface Args {
  snapshots: string;
  top: number;
  repeats: number;
  maxStates: number;
  maxCapturedWall: number;
}

function parseArgs(argv: string[]): Args {
  let snapshots = "";
  let top = 10;
  let repeats = 5;
  let maxStates = 10000;
  let maxCapturedWall = 30.0;
  for (const a of argv) {
    if (a.startsWith("--top=")) top = parseInt(a.slice("--top=".length), 10);
    else if (a.startsWith("--repeats=")) repeats = parseInt(a.slice("--repeats=".length), 10);
    else if (a.startsWith("--max-states=")) maxStates = parseInt(a.slice("--max-states=".length), 10);
    else if (a.startsWith("--max-captured-wall=")) maxCapturedWall = parseFloat(a.slice("--max-captured-wall=".length));
    else if (!a.startsWith("--")) snapshots = a;
  }
  if (!snapshots) {
    process.stderr.write("usage: node bench/perf_harness.ts <snapshots.jsonl> [--top=N --repeats=N --max-states=N]\n");
    process.exit(2);
  }
  return { snapshots, top, repeats, maxStates, maxCapturedWall };
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  let snaps = loadSnapshots(args.snapshots);
  if (snaps.length === 0) {
    process.stderr.write(`no snapshots in ${args.snapshots}\n`);
    process.exit(1);
  }
  snaps = snaps.filter(s => s.total_wall <= args.maxCapturedWall);
  snaps.sort((a, b) => b.total_wall - a.total_wall);
  const top = snaps.slice(0, args.top);

  console.log(
    `Loaded ${snaps.length} snapshots (post-filter); profiling top ${top.length} with ${args.repeats} repeats each, max_states=${args.maxStates}.\n`,
  );
  console.log("Per-case re-times:");

  const summaries: Summary[] = [];
  for (let i = 0; i < top.length; i++) {
    const { walls, lastStats } = timeOne(top[i]!, args.repeats, args.maxStates);
    const s = summarize(top[i]!, walls, lastStats);
    summaries.push(s);
    printSummary(i + 1, s);
  }

  if (top.length > 0) {
    console.log("\nProjection breakdown for the slowest case:");
    printProjectionBreakdown(top[0]!);
  }
}

main();
