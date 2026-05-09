// dump_session.ts — render a session's actions.jsonl as a
// human-readable DSL trace. Doubles as the smoke-test for
// JSONL framing: if any line fails to parse or any wire shape
// is malformed, this surfaces it as a parse error rather than a
// silent corruption.
//
// Usage:
//   node tools/dump_session.ts <session_id>            # full game
//   node tools/dump_session.ts --puzzle <session_id>   # puzzle V2
//
// Lines are emitted in DSL syntax (split / merge_stack /
// merge_hand / place_hand / move_stack / complete_turn /
// undo) threaded through a sim built from the session's
// initial state. Undo rewinds the sim so subsequent lines
// resolve their stack references against the correct board.
// A final-board summary follows the trace.

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../src/rules/card.ts";
import { cardLabel } from "../src/rules/card.ts";
import type { BoardStack } from "../src/geometry.ts";
import type { Primitive, Side } from "../src/primitives.ts";
import { applyLocally } from "../src/primitives.ts";
import { primToDslLine } from "../src/wire_json.ts";

interface JsonCard { value: number; suit: number; origin_deck: number }
interface JsonBoardCard { card: JsonCard; state: number }
interface JsonCardStack { board_cards: JsonBoardCard[]; loc: { top: number; left: number } }

function jsonCardToCard(c: JsonCard): Card {
  return [c.value, c.suit, c.origin_deck] as Card;
}

function jsonStackToBoardStack(s: JsonCardStack): BoardStack {
  return {
    cards: s.board_cards.map(b => jsonCardToCard(b.card)),
    loc: s.loc,
  };
}

/** Parse one wire-action envelope into a Primitive (or null for
 *  complete_turn / unknown). The wire shape includes embedded
 *  stack contents; we use those + the threaded sim to compute
 *  index-based primitives. */
function envelopeToPrim(
  action: any,
  sim: readonly BoardStack[],
): Primitive | null {
  switch (action?.action) {
    case "split": {
      const cards = (action.stack as JsonCardStack).board_cards.map(b => jsonCardToCard(b.card));
      const idx = findStackByCards(sim, cards);
      return { action: "split", stackIndex: idx, cardIndex: action.card_index };
    }
    case "merge_stack": {
      const src = (action.source as JsonCardStack).board_cards.map(b => jsonCardToCard(b.card));
      const tgt = (action.target as JsonCardStack).board_cards.map(b => jsonCardToCard(b.card));
      return {
        action: "merge_stack",
        sourceStack: findStackByCards(sim, src),
        targetStack: findStackByCards(sim, tgt),
        side: action.side as Side,
      };
    }
    case "merge_hand": {
      const tgt = (action.target as JsonCardStack).board_cards.map(b => jsonCardToCard(b.card));
      return {
        action: "merge_hand",
        targetStack: findStackByCards(sim, tgt),
        handCard: jsonCardToCard(action.hand_card),
        side: action.side as Side,
      };
    }
    case "place_hand":
      return {
        action: "place_hand",
        handCard: jsonCardToCard(action.hand_card),
        loc: action.loc,
      };
    case "move_stack": {
      const cards = (action.stack as JsonCardStack).board_cards.map(b => jsonCardToCard(b.card));
      return {
        action: "move_stack",
        stackIndex: findStackByCards(sim, cards),
        newLoc: action.new_loc,
      };
    }
    default:
      return null;
  }
}

function cardsKey(cards: readonly Card[]): string {
  return cards.map(c => `${c[0]},${c[1]},${c[2]}`).join("|");
}

function findStackByCards(sim: readonly BoardStack[], cards: readonly Card[]): number {
  const want = cardsKey(cards);
  for (let i = 0; i < sim.length; i++) {
    if (cardsKey(sim[i]!.cards) === want) return i;
  }
  throw new Error(`stack not found on board: [${cards.map(c => `${c[0]},${c[1]},${c[2]}`).join(" ")}]`);
}

function formatStack(s: BoardStack): string {
  return `[${s.cards.map(cardLabel).join(" ")}] @ (${s.loc.top},${s.loc.left})`;
}

function main(): void {
  const args = process.argv.slice(2);
  let isPuzzle = false;
  const positional: string[] = [];
  for (const a of args) {
    if (a === "--puzzle") isPuzzle = true;
    else positional.push(a);
  }
  if (positional.length < 1) {
    console.error("usage: node tools/dump_session.ts [--puzzle] <session_id>");
    process.exit(2);
  }
  const sessionId = positional[0]!;

  const dataRoot = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    "../../data",
  );

  const sessionDir = isPuzzle
    ? path.join(dataRoot, "puzzle", "sessions", sessionId)
    : path.join(dataRoot, "lynrummy-elm", "sessions", sessionId);
  const actionsPath = path.join(sessionDir, "actions.jsonl");
  const metaPath = path.join(sessionDir, "meta.json");

  if (!fs.existsSync(actionsPath)) {
    console.error(`no actions.jsonl at ${actionsPath}`);
    process.exit(1);
  }

  // Build sim from meta. Full game uses `initial_state.board`;
  // puzzle V2 uses `initial_board` directly.
  let sim: readonly BoardStack[] = [];
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
    const initial = isPuzzle ? meta?.initial_board : meta?.initial_state?.board;
    if (Array.isArray(initial)) {
      sim = (initial as JsonCardStack[]).map(jsonStackToBoardStack);
    }
  }

  const text = fs.readFileSync(actionsPath, "utf8");
  const lines = text.split("\n").filter(l => l.length > 0);
  const out: string[] = [];
  out.push(`# session ${sessionId}${isPuzzle ? " (puzzle)" : ""} — ${lines.length} actions`);
  out.push("");

  // Undo stack: pre-action sim snapshots + descriptions, one
  // per board-mutating action. CompleteTurn clears the stack
  // (undo can't cross a turn boundary). Undo pops the stack
  // and rewinds sim. Mirrors the Game.ActionLog.collapseUndos
  // semantics on the Elm side.
  const undoStack: { simBefore: readonly BoardStack[]; descrip: string }[] = [];

  for (const line of lines) {
    let env: { seq: number; action: any };
    try {
      env = JSON.parse(line);
    } catch (e) {
      out.push(`!! parse error: ${(e as Error).message} on line: ${line.slice(0, 80)}`);
      continue;
    }
    const a = env.action;
    const seqStr = String(env.seq).padStart(3);

    if (a?.action === "complete_turn") {
      out.push(`${seqStr}  complete_turn`);
      undoStack.length = 0;
      continue;
    }

    if (a?.action === "undo") {
      const top = undoStack.pop();
      if (top) {
        sim = top.simBefore;
        out.push(`${seqStr}  undo  (cancels: ${top.descrip})`);
      } else {
        out.push(`${seqStr}  undo  (no-op)`);
      }
      continue;
    }

    const prim = envelopeToPrim(a, sim);
    if (prim === null) {
      out.push(`${seqStr}  ?? ${a?.action ?? "unknown"}`);
      continue;
    }
    const descrip = primToDslLine(prim, sim);
    out.push(`${seqStr}  ${descrip}`);
    undoStack.push({ simBefore: sim, descrip });
    sim = applyLocally(sim, prim);
  }

  out.push("");
  out.push(`# final board (${sim.length} stack${sim.length === 1 ? "" : "s"})`);
  for (const s of sim) {
    out.push(`  ${formatStack(s)}`);
  }

  process.stdout.write(out.join("\n") + "\n");
}

main();
