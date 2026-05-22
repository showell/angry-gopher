// validate_puzzle_dsl.ts — run every puzzle in a catalog .dsl through
// solveBoard and print its plan (solvability + move list). Handy for
// hand-crafted catalogs that have no conformance test. Usage:
//
//   node tools/validate_puzzle_dsl.ts ../conformance/curated_1line_puzzles.dsl
//
// Prints, per puzzle: name, plan length, and each verb-level move line.
// Exits non-zero if any puzzle is unsolvable.

import * as fs from "node:fs";

import { type Card } from "../core/card.ts";
import { solveBoard } from "../bfs/engine_v2.ts";
import { parseBoardStackLine } from "../dsl/parse.ts";

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
      if (current !== null) out.push({ name: current.name, board: current.cards });
      current = { name: header[1]!, cards: [] };
      continue;
    }
    if (current === null || trimmed === "") continue;
    if (trimmed.startsWith("at ")) {
      current.cards.push([...parseBoardStackLine(trimmed).cards]);
    }
  }
  if (current !== null) out.push({ name: current.name, board: current.cards });
  return out;
}

function main(): void {
  const file = process.argv[2];
  if (!file) {
    console.error("usage: node tools/validate_puzzle_dsl.ts <catalog.dsl>");
    process.exit(2);
  }
  const puzzles = parsePuzzles(fs.readFileSync(file, "utf8"));
  let failures = 0;
  for (const p of puzzles) {
    const result = solveBoard(p.board);
    if (result === null) {
      console.log(`FAIL  ${p.name}  — unsolvable (no plan)`);
      failures++;
      continue;
    }
    console.log(`OK    ${p.name}  — plan length ${result.plan.length}`);
    for (const step of result.plan) console.log(`        ${step.line}`);
  }
  console.log(`\n${puzzles.length - failures}/${puzzles.length} solvable`);
  if (failures > 0) process.exit(1);
}

main();
