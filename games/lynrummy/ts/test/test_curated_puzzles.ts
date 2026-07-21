// test_curated_puzzles.ts — conformance for the curated puzzle
// catalogs. For each plan length in PLAN_LENGTHS, opens the
// matching `games/lynrummy/conformance/curated_<N>line_puzzles.dsl`
// file, parses every `puzzle <name>` block, runs solveBoard,
// and asserts:
//
//   - the BFS finds a non-null plan (puzzle is solvable)
//   - the plan length is exactly N
//
// To add a new catalog (e.g. 3-line), drop the seed file at the
// matching path and add the length to PLAN_LENGTHS.
//
// Format note: the puzzle DSL is the UI-consumable shape from
// mined_seeds.dsl — `puzzle X` headers + indented `at (left,
// top): cards` bodies. The same blocks the server (`puzzles.zig`)
// reads to serve the puzzle UI; running them through BFS here is the
// solvability + plan-length guarantee that backs the UI.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import { type Card } from "../core/card.ts";
import { solveBoard, PUZZLE_MAX_PLAN_LENGTH } from "../bfs/engine_v2.ts";
import { parseBoardStackLine } from "../dsl/parse.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// Every puzzle here is solved at PUZZLE_MAX_PLAN_LENGTH — the SAME cap
// the puzzle UI's Hint uses (elmPuzzleHint) — so what the tests prove
// and what the UI hints at can't drift. That's why the 6-line catalog
// is now included: the puzzle path searches deeper than the agent, so
// its 6-move solutions are reachable (they aren't at the agent's cap of
// 5). If a deeper catalog is added, add its length here AND make sure
// PUZZLE_MAX_PLAN_LENGTH covers it — this test will fail loudly if not.
const PLAN_LENGTHS: readonly number[] = [4, 5, 6];

function catalogPath(planLength: number): string {
  return path.resolve(
    __dirname,
    `../../conformance/curated_${planLength}line_puzzles.dsl`,
  );
}

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

function runPuzzle(p: ParsedPuzzle, expectedLength: number): RunResult {
  const result = solveBoard(p.board, PUZZLE_MAX_PLAN_LENGTH);
  if (result === null) {
    return { ok: false, msg: `no plan found (expected plan of length ${expectedLength})` };
  }
  if (result.plan.length !== expectedLength) {
    return {
      ok: false,
      msg: `plan length ${result.plan.length}, expected ${expectedLength}`,
    };
  }
  return { ok: true, msg: `OK — plan of length ${result.plan.length}` };
}

function runCatalog(planLength: number, failures: string[]): { passed: number; total: number } {
  const dslPath = catalogPath(planLength);
  if (!fs.existsSync(dslPath)) {
    console.error(`missing puzzle DSL: ${dslPath}`);
    process.exit(1);
  }
  const puzzles = parsePuzzles(fs.readFileSync(dslPath, "utf8"));
  if (puzzles.length === 0) {
    console.error(`no puzzles parsed from ${dslPath}`);
    process.exit(1);
  }

  console.log(`\n${planLength}-line catalog (${puzzles.length} puzzles):`);
  let passed = 0;
  for (const p of puzzles) {
    // stretch_ puzzles are human-stretch boards served past the curated
    // catalog: no plan-length contract, and the BFS can't touch them
    // anyway (trouble cap). Their ground truth lives with the zig
    // solver (see the DSL comment block); here they are only carried.
    if (p.name.startsWith("stretch_")) {
      console.log(`  SKIP  ${p.name.padEnd(60)}  stretch puzzle: no plan-length contract`);
      continue;
    }
    const t0 = Date.now();
    const r = runPuzzle(p, planLength);
    const ms = Date.now() - t0;
    const tag = ms >= 100 ? `  [${ms}ms]` : "";
    const status = r.ok ? "PASS" : "FAIL";
    const line = `  ${status}  ${p.name.padEnd(60)}  ${r.msg}${tag}`;
    console.log(line);
    if (r.ok) {
      passed++;
    } else {
      failures.push(line);
    }
  }
  return { passed, total: puzzles.length };
}

export function main(): void {
  const failures: string[] = [];
  let totalPassed = 0;
  let totalCount = 0;
  for (const planLength of PLAN_LENGTHS) {
    const { passed, total } = runCatalog(planLength, failures);
    totalPassed += passed;
    totalCount += total;
  }

  console.log();
  console.log(`${totalPassed}/${totalCount} curated puzzles passed`);

  if (failures.length > 0) {
    console.log();
    console.log("FAILURES:");
    for (const f of failures) console.log("  " + f);
    process.exit(1);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
