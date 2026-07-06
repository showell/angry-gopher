// replay_session.ts — reconstruct a live game from its session log and
// audit every hint along the way.
//
// Usage (from games/lynrummy/ts):
//   node --experimental-strip-types tools/replay_session.ts <session_dir>
// e.g. <session_dir> = ~/AngryGopher/local/lynrummy/16/lynrummy-elm/sessions/5
//
// Replays `{meta, actions.dsl}` through the TS primitives layer —
// collapsing undos, skipping drag-artifact empty splits, tracking both
// hands through the 0/3/5 draw rules (Lib/CompleteTurn.elm) and the
// sticky hand-loner flag (Lib/ActionLog.stepHandLonerFlag) — and at
// EVERY intermediate state computes the hint the player would see.
// Reports any hint containing engine-speak (a compressHint bail), then
// prints the final board, hand, and hint. This is the diagnosis tool
// for the "Steve user-tests the Hint button" working mode: point it at
// the session, and the state + hint he's looking at falls out.
//
// Reads game data only; writes nothing; exits 0.

import * as fs from "node:fs";
import { type Card, parseCardLabel, cardLabel } from "../core/card.ts";
import { isCompleteGroup } from "../core/card_stack.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { applyLocally } from "../game_events/primitives.ts";
import { parseWireActionLine } from "../game_events/parse_game_event.ts";
import { gameHintLines } from "../elm_api/engine_entry.ts";

const sessionDir = process.argv[2];
if (sessionDir === undefined) {
  console.error("usage: replay_session.ts <session_dir>");
  process.exit(1);
}

// --- initial board + hands + deck from meta ---

const meta = fs.readFileSync(`${sessionDir}/meta`, "utf8");

function parseDslCard(label: string): Card {
  // Session DSL uses a trailing `'` for deck 2; the internal label uses `:1`.
  return parseCardLabel(label.endsWith("'") ? label.slice(0, -1) + ":1" : label);
}

function metaHand(header: string): Card[] {
  const lines = meta.split("\n");
  const start = lines.findIndex(l => l.startsWith(header));
  const out: Card[] = [];
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i]!.trim();
    if (l === "" || /^Player|^deck:/.test(l)) break;
    out.push(...l.split(/\s+/).map(parseDslCard));
  }
  return out;
}

let board: readonly BoardStack[] = [];
for (const line of meta.split("\n")) {
  const m = line.match(/^\s+at \(\s*(-?\d+),\s*(-?\d+)\):\s*(.+)$/);
  if (!m) continue;
  board = [...board, {
    cards: m[3]!.trim().split(/\s+/).map(parseDslCard),
    loc: { left: parseInt(m[1]!, 10), top: parseInt(m[2]!, 10) },
  }];
}

const hands: Card[][] = [metaHand("Player One Hand:"), metaHand("Player Two Hand:")];
const deck: Card[] = meta.match(/^deck: (.+)$/m)![1]!.trim().split(/\s+/).map(parseDslCard);
let active = parseInt(meta.match(/^active_player: (\d+)$/m)![1]!, 10);
let playedThisTurn = 0;
let loner = false;

function playFromHand(label: string): void {
  const card = parseDslCard(label);
  const i = hands[active]!.findIndex(c =>
    c.rank === card.rank && c.suit === card.suit && c.deck === card.deck);
  if (i < 0) throw new Error(`player ${active} played ${label} not in their hand`);
  hands[active]!.splice(i, 1);
  playedThisTurn++;
}

// --- collapse undos, then replay ---

const rawLines = fs.readFileSync(`${sessionDir}/actions.dsl`, "utf8")
  .split("\n").map(s => s.trim()).filter(s => s.length > 0);
const collapsed: string[] = [];
for (const line of rawLines) {
  if (/^\d+\)\s*undo$/.test(line)) collapsed.pop();
  else collapsed.push(line);
}

const stats = { states: 0, human: 0, none: 0, raw: 0 };

for (const line of collapsed) {
  // Drag-artifact splits with an empty chunk are loc no-ops in the live
  // log (e.g. `split  / Q♦` — the next action reuses the same loc).
  if (/^\d+\)\s*split\s+\//.test(line)) continue;
  const handPlay = line.match(/^\d+\)\s*(?:merge_hand|place_hand) (\S+)/);
  if (handPlay !== null) playFromHand(handPlay[1]!);
  const prim = parseWireActionLine(line, board);
  if ("action" in prim && prim.action === "complete_turn") {
    // Lib/CompleteTurn.elm: outgoing player draws 0/3/5, then seat cycles.
    const drawCount = playedThisTurn === 0 ? 3 : hands[active]!.length === 0 ? 5 : 0;
    hands[active]!.push(...deck.splice(0, drawCount));
    active = 1 - active;
    playedThisTurn = 0;
    continue;
  }
  board = applyLocally(board, prim);
  // Lib/ActionLog.stepHandLonerFlag: a clean board clears the flag;
  // place_hand sets it; anything else carries it.
  if (board.every(s => isCompleteGroup(s.cards))) loner = false;
  else if (/^\d+\)\s*place_hand /.test(line)) loner = true;

  // The hint the player would see if they pressed Hint right now.
  const hint = gameHintLines(hands[active]!, board.map(s => s.cards), loner);
  const isRaw = hint.some(l =>
    l.includes("HELPER [") || l.includes(" → ") || /^place \[/.test(l));
  stats.states++;
  if (hint.length === 0) stats.none++;
  else if (isRaw) {
    stats.raw++;
    console.log(`RAW hint after "${line.slice(0, 55)}" (loner=${loner})`);
    console.log(`  hand: ${hands[active]!.map(cardLabel).join(" ")}`);
    console.log(`  board: ${board.map(s => s.cards.map(cardLabel).join(" ")).join(" | ")}`);
    for (const l of hint) console.log("    " + l);
  } else stats.human++;
}

console.log(`swept ${stats.states} states: `
  + `human=${stats.human} none=${stats.none} RAW=${stats.raw}`);

console.log("\nfinal board:");
for (const s of board) {
  console.log(`  at (${s.loc.left},${s.loc.top}): ${s.cards.map(cardLabel).join(" ")}`);
}
console.log(`\nactive player: ${active}, loner: ${loner}, `
  + `hand: ${hands[active]!.map(cardLabel).join(" ")}`);

const finalHint = gameHintLines(hands[active]!, board.map(s => s.cards), loner);
console.log(`\ncurrent hint (${finalHint.length} lines):`);
for (const l of finalHint) console.log("  " + l);
