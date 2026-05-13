// budget_sweep.ts — replay every captured projection at varying
// max_states budgets. Reports, per budget, how many projections still
// find a plan vs how many are sacrificed.
//
// TS port of python/budget_sweep.py.
//
// The OPTIMIZE question: can we cut the BFS state budget without
// losing many plans? If "lower it 10× and 98% still find their plan,"
// that's a free perf win at the cost of perfect agent play on the
// rare hard case.
//
// Usage:
//   node bench/budget_sweep.ts /tmp/perf_snapshots.jsonl

import * as fs from "node:fs";

import { type Card, type Rank, type Suit, type Deck } from "../core/card.ts";
import { solveBoard } from "../bfs/index.ts";

const BUDGETS = [200000, 50000, 20000, 10000, 5000, 2000, 1000];

interface CapturedProjection {
  kind: string;
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
  return { rank: c[0]! as Rank, suit: c[1]! as Suit, deck: c[2]! as Deck };
}

function augmentedBoard(
  board: readonly (readonly Card[])[],
  extraStacks: readonly (readonly Card[])[],
): readonly (readonly Card[])[] {
  return [...board, ...extraStacks];
}

function runProjection(
  board: readonly (readonly Card[])[],
  maxStates: number,
): { found: boolean; wall: number } {
  const t0 = performance.now();
  const result = solveBoard(board, { maxTroubleOuter: 10, maxStates });
  const wall = (performance.now() - t0) / 1000;
  return { found: result !== null, wall };
}

function main(): void {
  const argv = process.argv.slice(2);
  const path = argv[0];
  if (!path) {
    process.stderr.write("usage: node bench/budget_sweep.ts <snapshots.jsonl>\n");
    process.exit(2);
    return;
  }

  const snaps: CapturedSnapshot[] = [];
  const text = fs.readFileSync(path, "utf8");
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    const s = JSON.parse(line) as CapturedSnapshot;
    if (s.total_wall < 30) snaps.push(s);
  }

  interface Case {
    board: readonly (readonly Card[])[];
    kind: string;
    capturedFound: boolean;
    capturedWall: number;
  }

  const cases: Case[] = [];
  for (const snap of snaps) {
    const board = snap.board.map(s => s.map(asCard));
    for (const proj of snap.projections) {
      const extra = [proj.cards.map(asCard)];
      cases.push({
        board: augmentedBoard(board, extra),
        kind: proj.kind,
        capturedFound: proj.found_plan,
        capturedWall: proj.wall,
      });
    }
  }

  const capturedFound = cases.filter(c => c.capturedFound).length;
  console.log(`Replaying ${cases.length} projections at varying budgets.`);
  console.log(`Capture baseline: ${capturedFound}/${cases.length} found a plan.\n`);
  console.log(`${"budget".padStart(8)} ${"found".padStart(8)} ${"lost_vs_baseline".padStart(18)} ${"total_wall".padStart(12)}`);
  console.log("-".repeat(55));

  for (const budget of BUDGETS) {
    let foundNow = 0;
    let totalWall = 0.0;
    let lost = 0;
    for (const c of cases) {
      const { found, wall } = runProjection(c.board, budget);
      totalWall += wall;
      if (found) foundNow++;
      else if (c.capturedFound) lost++;
    }
    console.log(
      `${String(budget).padStart(8)} ${String(foundNow).padStart(8)} ${String(lost).padStart(18)} ${(totalWall.toFixed(2) + "s").padStart(12)}`,
    );
  }
}

main();
