// initial_state_dsl.ts — emit the multi-section GameState DSL
// Elm's Lib.InitialStateDsl parses on the resume path.
//
// Document shape (same as Lib.InitialStateDsl.formatGameState):
//
//   board:
//     at ( 26,  26): 2♥ 3♥ 4♥
//
//   Player One Hand:
//     2♥ 5♥ J♥
//     A♠ 3♠ K♠
//
//   Player Two Hand:
//     3♥ 4♥
//
//   deck: K♣ Q♣' J♣ ...
//
//   active_player: 0
//   turn_index: 0
//   cards_played_this_turn: 0
//   victor_awarded: false
//
// The board block uses width-3 padded coords so the `): `
// separator lines up across stacks; suits and values come out
// in unicode form so the wire stream is byte-identical to what
// Elm emits.

import { type Card, parseCardLabel, cardToken } from "../core/card.ts";
import type { Stack } from "../game_events/emit_game_event.ts";
import type { BoardStack, Loc } from "../core/geometry.ts";


export interface GameStateForDsl {
  readonly board: readonly Stack[];
  /** Length-2 list: [player_one_hand, player_two_hand]. */
  readonly hands: readonly (readonly Card[])[];
  readonly deck: readonly Card[];
  readonly activePlayer: number;
  readonly turnIndex: number;
  readonly cardsPlayedThisTurn: number;
  readonly victorAwarded: boolean;
}


export function formatGameState(s: GameStateForDsl): string {
  const sections: string[] = [];
  sections.push(formatBoardBlock(s.board));
  sections.push(formatHandBlock("Player One Hand", s.hands[0] ?? []));
  sections.push(formatHandBlock("Player Two Hand", s.hands[1] ?? []));
  sections.push(formatDeckLine(s.deck));
  sections.push(formatScalars(s));
  return sections.join("\n\n");
}


// --- BOARD -----------------------------------------------------------

export function formatBoardBlock(board: readonly Stack[]): string {
  const body = board.map(formatBoardLine).join("\n");
  return body === "" ? "board:" : "board:\n" + body;
}

export function formatBoardLine(stack: Stack): string {
  return "  at ("
    + padCoord(stack.loc.top)
    + ", "
    + padCoord(stack.loc.left)
    + "): "
    + stack.cards.map(cardToken).join(" ");
}

function padCoord(n: number): string {
  return String(n).padStart(3, " ");
}


// --- HANDS -----------------------------------------------------------

// Mirror of the Elm hand-view's suit-row layout: one row per
// non-empty suit, suits in UI order (Heart, Spade, Diamond,
// Club), cards within a row sorted ascending by value.

const SUIT_DISPLAY_ORDER: readonly number[] = [3, 2, 1, 0]; // H, S, D, C

export function formatHandBlock(header: string, hand: readonly Card[]): string {
  const rows = sortIntoSuitRows(hand).map(formatHandRow);
  return rows.length === 0 ? header + ":" : header + ":\n" + rows.join("\n");
}

export function sortIntoSuitRows(hand: readonly Card[]): (readonly Card[])[] {
  const rows: (readonly Card[])[] = [];
  for (const suit of SUIT_DISPLAY_ORDER) {
    const inSuit = hand
      .filter(c => c.suit === suit)
      .sort((a, b) => a.rank - b.rank);
    if (inSuit.length > 0) rows.push(inSuit);
  }
  return rows;
}

function formatHandRow(cards: readonly Card[]): string {
  return "  " + cards.map(cardToken).join(" ");
}


// --- DECK + SCALARS --------------------------------------------------

export function formatDeckLine(deck: readonly Card[]): string {
  return "deck: " + deck.map(cardToken).join(" ");
}

function formatScalars(s: GameStateForDsl): string {
  return [
    "active_player: " + s.activePlayer,
    "turn_index: " + s.turnIndex,
    "cards_played_this_turn: " + s.cardsPlayedThisTurn,
    "victor_awarded: " + (s.victorAwarded ? "true" : "false"),
  ].join("\n");
}


// --- PARSE (BOARD ONLY) ----------------------------------------------
//
// Session validation only needs the starting board to replay
// against. Hands / deck / scalars are encoded for the resume
// path but the validator doesn't need them — the agent's
// transcript references board stacks by content, and stack
// indices are recomputed against the live sim board.

/** Extract the board stacks from a meta DSL document. Walks
 *  lines, takes the `board:` block, parses each indented
 *  `at (top, left): cards` line. */
export function parseBoardFromMeta(metaDsl: string): readonly BoardStack[] {
  const lines = metaDsl.split("\n");
  const out: BoardStack[] = [];
  let inBoard = false;
  for (const raw of lines) {
    const trimmed = raw.trim();
    if (trimmed === "board:") {
      inBoard = true;
      continue;
    }
    if (inBoard) {
      if (trimmed === "" || !raw.startsWith(" ")) break;
      const m = trimmed.match(/^at\s*\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)\s*:\s*(.+)$/);
      if (!m) {
        throw new Error(`board line did not parse: ${trimmed}`);
      }
      const top = parseInt(m[1]!, 10);
      const left = parseInt(m[2]!, 10);
      const cards = m[3]!.trim().split(/\s+/).map(parseMetaCard);
      out.push({ cards, loc: { top, left } as Loc });
    }
  }
  return out;
}


function parseMetaCard(s: string): Card {
  const tsLabel = s.endsWith("'") ? s.slice(0, -1) + ":1" : s;
  return parseCardLabel(tsLabel);
}
