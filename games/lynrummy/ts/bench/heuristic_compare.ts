// Compare A* heuristics on the medium-tier scenarios.

import * as fs from "node:fs";
import * as path from "node:path";

import { solveTurn, HEURISTICS, lastVisits, type Heuristic } from "../src/engine_v2.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { type Card } from "../src/rules/card.ts";
import { verifyCleanBoard } from "./verify_clean_board.ts";

interface BoardCard { card: { value: number; suit: number; origin_deck: number } }
interface BoardStack { board_cards: BoardCard[] }
interface Scenario {
  name: string; op: string;
  helper?: BoardStack[]; trouble?: BoardStack[]; growing?: BoardStack[]; complete?: BoardStack[];
  expect: Record<string, unknown>;
}

const FIXTURES = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../python/conformance_fixtures.json");
function bucketToTuples(stacks: BoardStack[] | undefined): Card[][] {
  if (!stacks) return [];
  return stacks.map(s => s.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as const));
}
function buildRaw(sc: Scenario): RawBuckets {
  return {
    helper: bucketToTuples(sc.helper),
    trouble: bucketToTuples(sc.trouble),
    growing: bucketToTuples(sc.growing),
    complete: bucketToTuples(sc.complete),
  };
}
function nowMs() { const [s, ns] = process.hrtime(); return s * 1000 + ns / 1e6; }

const all: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES, "utf8"));
const targets = ["corpus_sid_130","corpus_sid_116","corpus_sid_110","corpus_sid_146","mined_mined_006_2Cp1","corpus_sid_122","corpus_sid_114","corpus_sid_118","mined_mined_001_2Hp1","mined_mined_004_6H","corpus_sid_138","corpus_sid_112"];

const heuristicNames = Object.keys(HEURISTICS);

console.log(`Comparing ${heuristicNames.length} heuristics on ${targets.length} scenarios:\n`);
console.log(`${"scenario".padEnd(28)} ${heuristicNames.map(n => n.padStart(14)).join("  ")}`);

for (const name of targets) {
  const sc = all.find(s => s.name === name);
  if (!sc) continue;
  const initial = classifyBuckets(buildRaw(sc));
  const expectedLen = (sc.expect?.plan_length as number | undefined) ?? (sc.expect?.plan_lines as string[] | undefined)?.length ?? 0;

  const cells: string[] = [];
  for (const hname of heuristicNames) {
    const h = HEURISTICS[hname]!;
    const t0 = nowMs();
    const plan = solveTurn(initial, { budget: 50000, heuristic: h });
    const ms = nowMs() - t0;
    if (plan === null) {
      cells.push("STUCK".padStart(14));
    } else {
      const len = plan.length;
      const tag = len === expectedLen ? "" : len > expectedLen ? "+" : "-";
      const v = verifyCleanBoard(initial, plan);
      const cell = v.ok ? `${len}${tag}/${lastVisits}/${ms.toFixed(0)}ms` : "INVALID";
      cells.push(cell.padStart(14));
    }
  }
  console.log(`${name.padEnd(28)} ${cells.join("  ")}`);
}
console.log(`\n(Cell format: <length><tag>/<visits>/<wallms>; tag '+' = longer than expected, '-' = shorter)`);
