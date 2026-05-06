// dump_session.ts — render a session's actions.jsonl as a
// human-readable DSL trace. Doubles as the smoke-test for
// JSONL framing: if any line fails to parse or any wire shape
// is malformed, this surfaces it as a parse error rather than a
// silent corruption.
//
// Usage:
//   node tools/dump_session.ts <session_id>          # full game
//   node tools/dump_session.ts <session_id> <name>   # puzzle session
//
// Lines are emitted in DSL syntax (split / merge_stack /
// merge_hand / place_hand / move_stack / complete_turn) just
// like trace_game.ts, threaded through a sim built from the
// session's meta.initial_state when present. CompleteTurn
// breaks emit "complete_turn" verbatim.

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../src/rules/card.ts";
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

function main(): void {
  const args = process.argv.slice(2);
  if (args.length < 1) {
    console.error("usage: node tools/dump_session.ts <session_id> [<puzzle_name>]");
    process.exit(2);
  }
  const sessionId = args[0]!;
  const puzzleName = args[1];

  const dataRoot = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    "../../data/lynrummy-elm",
  );

  let sessionDir: string;
  let actionsPath: string;
  let metaPath: string;
  if (puzzleName) {
    sessionDir = path.join(dataRoot, "puzzle-sessions", sessionId, puzzleName);
    actionsPath = path.join(sessionDir, "actions.jsonl");
    metaPath = path.join(dataRoot, "puzzle-sessions", sessionId, "meta.json");
  } else {
    sessionDir = path.join(dataRoot, "sessions", sessionId);
    actionsPath = path.join(sessionDir, "actions.jsonl");
    metaPath = path.join(sessionDir, "meta.json");
  }

  if (!fs.existsSync(actionsPath)) {
    console.error(`no actions.jsonl at ${actionsPath}`);
    process.exit(1);
  }

  // Build sim from meta.initial_state when present. Puzzle
  // sessions don't carry an initial_state in their session-level
  // meta (the puzzle catalog supplies it); for puzzles, sim
  // starts empty and grows from place_hand actions.
  let sim: readonly BoardStack[] = [];
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
    const initial = meta?.initial_state?.board;
    if (Array.isArray(initial)) {
      sim = (initial as JsonCardStack[]).map(jsonStackToBoardStack);
    }
  }

  const text = fs.readFileSync(actionsPath, "utf8");
  const lines = text.split("\n").filter(l => l.length > 0);
  const out: string[] = [];
  out.push(`# session ${sessionId}${puzzleName ? `/${puzzleName}` : ""} — ${lines.length} actions`);
  out.push("");

  for (const line of lines) {
    let env: { seq: number; action: any };
    try {
      env = JSON.parse(line);
    } catch (e) {
      out.push(`!! parse error: ${(e as Error).message} on line: ${line.slice(0, 80)}`);
      continue;
    }
    const a = env.action;
    if (a?.action === "complete_turn") {
      out.push(`${String(env.seq).padStart(3)}  complete_turn`);
      continue;
    }
    const prim = envelopeToPrim(a, sim);
    if (prim === null) {
      out.push(`${String(env.seq).padStart(3)}  ?? ${a?.action ?? "unknown"}`);
      continue;
    }
    out.push(`${String(env.seq).padStart(3)}  ${primToDslLine(prim, sim)}`);
    sim = applyLocally(sim, prim);
  }

  process.stdout.write(out.join("\n") + "\n");
}

main();
