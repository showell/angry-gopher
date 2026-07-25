// replay_puzzle.ts — replay a puzzle-mode gesture log over its catalog
// board and print the final arrangement in the zig wire format, ready
// to paste into zig/calib.zig for the human-vs-solver grading ritual
// (kept edges + distilled verbs; puzzles 78/79/80 precedent).
//
// Usage (from games/lynrummy/ts):
//   node --experimental-strip-types tools/replay_puzzle.ts <session_puzzle_dir> <puzzle_name>
// e.g. <session_puzzle_dir> = ~/AngryGopher/local/lynrummy/16/puzzle/sessions/23/puzzle_79
//      <puzzle_name>        = sim_s441t5   (a name in curated_sim_puzzles.dsl)
//
// Collapses undos, skips drag-artifact empty splits, and asserts the
// end state is all complete melds — a partial solve fails loud.
//
// Reads game data only; writes nothing; exits 0.

import * as fs from "node:fs";
import { type Card, parseCardLabel } from "../core/card.ts";
import { isCompleteGroup } from "../core/card_stack.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { applyLocally } from "../game_events/primitives.ts";
import { parseWireActionLine } from "../game_events/parse_game_event.ts";
import { formatBoardStackLine } from "../dsl/emit.ts";
import { zigAgentInput } from "../elm_api/zig_agent.ts";

const sessionDir = process.argv[2];
const puzzleName = process.argv[3];
if (sessionDir === undefined || puzzleName === undefined) {
  console.error("usage: replay_puzzle.ts <session_puzzle_dir> <puzzle_name>");
  process.exit(1);
}

function parseDslCard(label: string): Card {
  // Session/catalog DSL uses a trailing `'` for deck 2.
  return parseCardLabel(label.endsWith("'") ? label.slice(0, -1) + ":1" : label);
}

// --- catalog board ---

const catalog = fs.readFileSync(
  new URL("../../conformance/curated_sim_puzzles.dsl", import.meta.url), "utf8");
const block = catalog.split(/^puzzle /m).find(b => b.startsWith(puzzleName));
if (block === undefined) throw new Error(`puzzle ${puzzleName} not in curated_sim_puzzles.dsl`);
let board: readonly BoardStack[] = [];
for (const line of block.split("\n")) {
  const m = line.match(/^\s+at \(\s*(-?\d+),\s*(-?\d+)\):\s*(.+)$/);
  if (!m) continue;
  board = [...board, {
    cards: m[3]!.trim().split(/\s+/).map(parseDslCard),
    loc: { left: parseInt(m[1]!, 10), top: parseInt(m[2]!, 10) },
  }];
}
const original = board;

// --- collapse undos, replay ---

const rawLines = fs.readFileSync(`${sessionDir}/actions.dsl`, "utf8")
  .split("\n").map(s => s.trim()).filter(s => s.length > 0);
const collapsed: string[] = [];
let undos = 0;
for (const line of rawLines) {
  if (/^\d+\)\s*undo$/.test(line)) {
    collapsed.pop();
    undos++;
  } else collapsed.push(line);
}
let gestures = 0;
for (const line of collapsed) {
  // Drag-artifact splits with an empty chunk are loc no-ops in the live
  // log (e.g. `split  / Q♦` — the next action reuses the same loc).
  if (/^\d+\)\s*split\s+\//.test(line)) continue;
  const prim = parseWireActionLine(line, board);
  board = applyLocally(board, prim);
  gestures++;
}

if (!board.every(s => isCompleteGroup(s.cards))) {
  throw new Error("final board is not all complete melds — partial solve?");
}

function wireOf(b: readonly BoardStack[]): string {
  return zigAgentInput(b.map(formatBoardStackLine).join("\n"), "").split("\n")[0]!;
}

console.log(`gestures: ${gestures} effective (${undos} undos collapsed)`);
console.log(`final stacks: ${board.length}, all complete melds`);
console.log("ORIG  = " + wireOf(original));
console.log("FINAL = " + wireOf(board));
