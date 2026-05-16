// test_curated_puzzles.ts — conformance for the curated puzzle
// catalog. For each `puzzle <name>` block in
// games/lynrummy/conformance/curated_4line_puzzles.dsl, parse
// the board, run solveBoard, and assert:
//
//   - the BFS finds a non-null plan (puzzle is solvable)
//   - the plan length is exactly EXPECTED_PLAN_LENGTH
//
// The expected length is a per-FILE constant — this runner is
// for the 4-line catalog specifically. If we add a 3-line or
// 5-line catalog later, each gets its own runner OR this one
// gets parameterized by filename.
//
// Format note: the puzzle DSL is the UI-consumable shape from
// mined_seeds.dsl — `puzzle X` headers + indented `at (left,
// top): cards` bodies. The same blocks views/puzzle.go reads to
// serve the puzzle UI; running them through BFS here is the
// solvability + plan-length guarantee that backs the UI.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import { type Card } from "../core/card.ts";
import { solveBoard } from "../bfs/engine_v2.ts";
import { parseBoardStackLine } from "../dsl/parse.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PUZZLE_DSL_PATH = path.resolve(
  __dirname,
  "../../conformance/curated_4line_puzzles.dsl",
);
const EXPECTED_PLAN_LENGTH = 4;

interface ParsedPuzzle {
  readonly name: string;
  readonly board: readonly (readonly Card[])[];
}

function parsePuzzles(text: string): ParsedPuzzle[] {
  const out: ParsedPuzzle[] = [];
  let current: { name: string; cards: Card[][] } | null = null;

  for (const raw of text.split("\n")) {
    const line = raw.replace(/#.*$/, "").trimEnd();
    const trimmed = line.trim();

    const header = trimmed.match(/^puzzle\s+(\S+)$/);
    if (header) {
      if (current !== null) {
        out.push({ name: current.name, board: current.cards });
      }
      current = { name: header[1]!, cards: [] };
      continue;
    }

    if (current === null) continue;
    if (trimmed === "") continue;

    if (trimmed.startsWith("at ")) {
      const stack = parseBoardStackLine(trimmed);
      current.cards.push([...stack.cards]);
    }
  }
  if (current !== null) {
    out.push({ name: current.name, board: current.cards });
  }
  return out;
}

interface RunResult {
  readonly ok: boolean;
  readonly msg: string;
}

function runPuzzle(p: ParsedPuzzle): RunResult {
  const result = solveBoard(p.board);
  if (result === null) {
    return { ok: false, msg: "no plan found (expected plan of length 4)" };
  }
  if (result.plan.length !== EXPECTED_PLAN_LENGTH) {
    return {
      ok: false,
      msg: `plan length ${result.plan.length}, expected ${EXPECTED_PLAN_LENGTH}`,
    };
  }
  return { ok: true, msg: `OK — plan of length ${result.plan.length}` };
}

export function main(): void {
  if (!fs.existsSync(PUZZLE_DSL_PATH)) {
    console.error(`missing puzzle DSL: ${PUZZLE_DSL_PATH}`);
    process.exit(1);
  }
  const text = fs.readFileSync(PUZZLE_DSL_PATH, "utf8");
  const puzzles = parsePuzzles(text);

  if (puzzles.length === 0) {
    console.error(`no puzzles parsed from ${PUZZLE_DSL_PATH}`);
    process.exit(1);
  }

  let passed = 0;
  let failed = 0;
  const failures: string[] = [];

  for (const p of puzzles) {
    const t0 = Date.now();
    const r = runPuzzle(p);
    const ms = Date.now() - t0;
    const tag = ms >= 100 ? `  [${ms}ms]` : "";
    if (r.ok) {
      passed++;
      console.log(`PASS  ${p.name.padEnd(60)}  ${r.msg}${tag}`);
    } else {
      failed++;
      const line = `FAIL  ${p.name.padEnd(60)}  ${r.msg}${tag}`;
      console.log(line);
      failures.push(line);
    }
  }

  console.log();
  console.log(`${passed}/${puzzles.length} curated puzzles passed`);

  if (failed > 0) {
    console.log();
    console.log("FAILURES:");
    for (const f of failures) console.log("  " + f);
    process.exit(1);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
