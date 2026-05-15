// test_replay_walkthroughs.ts — replay each `replay_walkthroughs.dsl`
// scenario through TS primitives.applyLocally and assert the final
// board is victory (every stack a length-3+ legal kind).
//
// 25 scenarios, ~15-20 primitives each. End-to-end coverage of the
// primitives layer + the geometry-loc evolution (split nudges, merge
// loc shifts, move_stack relocation). Doesn't pin specific
// intermediate primitives — the action stream IS the input — so it's
// permissive of geometry-config evolution as long as the committed
// streams still replay to victory.
//
// Companion to test_primitives_fixtures.ts (which pins per-plan-step
// primitive emission). Together they cover both per-step fidelity
// and end-to-end correctness.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import type { Card } from "../core/card.ts";
import { parseCardLabel, cardLabel } from "../core/card.ts";
import {
  type Primitive, type Side,
  applyLocally, findStackIndex,
  makeSplit, makeMergeStack, makeMergeHand, makeMoveStack, makePlaceHand,
} from "../game_events/primitives.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { findViolation } from "../geometry/geometry.ts";
import { classifyStack } from "../core/card_stack.ts";
import { parseBoardStackLine } from "../dsl/parse.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DSL_DIR = path.resolve(__dirname, "../../conformance/scenarios");
const DSL_PATH = path.join(DSL_DIR, "replay_walkthroughs.dsl");

// --- DSL card lists --------------------------------------------------

function parseDslCards(s: string): readonly Card[] {
  return s.trim().split(/\s+/).map(parseCardLabel);
}

// --- DSL parser -----------------------------------------------------

interface Walkthrough {
  readonly name: string;
  readonly board: readonly BoardStack[];
  readonly actions: readonly string[];   // DSL action lines
}

function parseDsl(contents: string): Walkthrough[] {
  const out: Walkthrough[] = [];
  const lines = contents.split("\n");
  let cur: { name: string; board: BoardStack[]; actions: string[] } | null = null;
  let inBoard = false;
  let inActions = false;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i]!;
    const stripped = raw.replace(/#.*$/, "").trimEnd();
    const trimmed = stripped.trim();
    if (trimmed === "") continue;

    const sc = trimmed.match(/^scenario\s+(\S+)$/);
    if (sc && raw.match(/^scenario\b/)) {
      if (cur) out.push(cur);
      cur = { name: sc[1]!, board: [], actions: [] };
      inBoard = false;
      inActions = false;
      continue;
    }
    if (cur === null) continue;

    if (trimmed === "board:") { inBoard = true; inActions = false; continue; }
    if (trimmed === "actions:") { inBoard = false; inActions = true; continue; }
    if (trimmed === "expect:") { inBoard = false; inActions = false; continue; }

    if (inBoard) {
      if (trimmed.startsWith("at ")) {
        cur.board.push(parseBoardStackLine(trimmed));
      }
      continue;
    }

    if (inActions) {
      const m = trimmed.match(/^-\s*(.+)$/);
      if (m) cur.actions.push(m[1]!.trim());
      continue;
    }
  }
  if (cur) out.push(cur);
  return out;
}

// --- DSL action → Primitive ----------------------------------------

function parseActionLine(
  line: string,
  board: readonly BoardStack[],
): Primitive {
  // split [content]@k
  let m = line.match(/^split\s+\[([^\]]+)\]@(-?\d+)$/);
  if (m) {
    const cards = parseDslCards(m[1]!);
    return makeSplit(board, findStackIndex(board, cards), parseInt(m[2]!, 10));
  }
  // merge_stack [src] -> [tgt] /side
  m = line.match(/^merge_stack\s+\[([^\]]+)\]\s*->\s*\[([^\]]+)\]\s*\/(left|right)$/);
  if (m) {
    const src = parseDslCards(m[1]!);
    const tgt = parseDslCards(m[2]!);
    return makeMergeStack(
      board,
      findStackIndex(board, src),
      findStackIndex(board, tgt),
      m[3]! as Side,
    );
  }
  // move_stack [content] -> (left,top)
  m = line.match(/^move_stack\s+\[([^\]]+)\]\s*->\s*\((-?\d+)\s*,\s*(-?\d+)\)$/);
  if (m) {
    const cards = parseDslCards(m[1]!);
    return makeMoveStack(
      board,
      findStackIndex(board, cards),
      { left: parseInt(m[2]!, 10), top: parseInt(m[3]!, 10) },
    );
  }
  // merge_hand <card> -> [tgt] /side
  m = line.match(/^merge_hand\s+(\S+)\s*->\s*\[([^\]]+)\]\s*\/(left|right)$/);
  if (m) {
    const tgt = parseDslCards(m[2]!);
    return makeMergeHand(
      board,
      findStackIndex(board, tgt),
      parseCardLabel(m[1]!),
      m[3]! as Side,
    );
  }
  // place_hand <card> -> (left,top)
  m = line.match(/^place_hand\s+(\S+)\s*->\s*\((-?\d+)\s*,\s*(-?\d+)\)$/);
  if (m) {
    return makePlaceHand(
      parseCardLabel(m[1]!),
      { left: parseInt(m[2]!, 10), top: parseInt(m[3]!, 10) },
    );
  }
  throw new Error(`unparseable action: ${line}`);
}

// --- Victory check -------------------------------------------------

function isVictory(board: readonly BoardStack[]): { ok: boolean; msg: string } {
  for (let i = 0; i < board.length; i++) {
    const s = board[i]!;
    const ccs = classifyStack(s.cards);
    if (ccs === null) {
      return {
        ok: false,
        msg: `stack ${i} ([${s.cards.map(cardLabel).join(" ")}]) failed to classify`,
      };
    }
    if (ccs.n < 3) {
      return {
        ok: false,
        msg: `stack ${i} length ${ccs.n} (${ccs.kind}) — not graduated`,
      };
    }
    if (ccs.kind !== "run" && ccs.kind !== "rb" && ccs.kind !== "set") {
      return {
        ok: false,
        msg: `stack ${i} kind ${ccs.kind} not a length-3+ legal kind`,
      };
    }
  }
  return { ok: true, msg: "" };
}

// --- Runner --------------------------------------------------------

interface RunResult {
  readonly ok: boolean;
  readonly msg: string;
}

function runWalkthrough(w: Walkthrough): RunResult {
  let board: readonly BoardStack[] = w.board;
  for (let i = 0; i < w.actions.length; i++) {
    const line = w.actions[i]!;
    let prim: Primitive;
    try {
      prim = parseActionLine(line, board);
    } catch (e) {
      return { ok: false, msg: `action[${i}]: ${(e as Error).message}` };
    }
    try {
      board = applyLocally(board, prim);
    } catch (e) {
      return { ok: false, msg: `apply[${i}] (${line}): ${(e as Error).message}` };
    }
    // Per-step geometry check — catch the moment any primitive
    // creates an overlap.
    const v = findViolation(board);
    if (v !== null) {
      const s = board[v]!;
      return {
        ok: false,
        msg: `intermediate geometry violation after action[${i}] (${line}): `
          + `stack ${v} [${s.cards.map(c => `${c.rank},${c.suit},${c.deck}`).join(" ")}] @ (${s.loc.top},${s.loc.left})`,
      };
    }
  }
  // GEOMETRY INVARIANT: the final board has no overlapping stacks
  // and every stack is in-bounds. Per Steve, 2026-05-03: "you cannot
  // place a stack on top of another stack. NO OVERLAPPING STACKS!!!"
  // Conformance is now geometry-aware at this boundary.
  const violation = findViolation(board);
  if (violation !== null) {
    const s = board[violation]!;
    return {
      ok: false,
      msg: `geometry violation at stack ${violation} `
        + `[${s.cards.map(c => `${c.rank},${c.suit},${c.deck}`).join(" ")}] @ (${s.loc.top},${s.loc.left})`,
    };
  }
  const v = isVictory(board);
  if (!v.ok) {
    return { ok: false, msg: `final-board not victory: ${v.msg}` };
  }
  return { ok: true, msg: `OK — ${w.actions.length} actions, ${board.length} legal final stacks (geometry clean)` };
}

function main(): void {
  if (!fs.existsSync(DSL_PATH)) {
    console.error(`no DSL at ${DSL_PATH}`);
    process.exit(1);
  }
  const contents = fs.readFileSync(DSL_PATH, "utf8");
  const walkthroughs: Walkthrough[] = parseDsl(contents);

  let passed = 0;
  let failed = 0;
  const failures: string[] = [];
  for (const w of walkthroughs) {
    const res = runWalkthrough(w);
    if (res.ok) { passed++; console.log(`PASS  ${w.name.padEnd(40)}  ${res.msg}`); }
    else {
      failed++;
      const line = `FAIL  ${w.name.padEnd(40)}  ${res.msg}`;
      console.log(line);
      failures.push(line);
    }
  }
  console.log();
  console.log(`${passed}/${walkthroughs.length} walkthroughs passed`);
  if (failed > 0) process.exit(1);
}

main();
