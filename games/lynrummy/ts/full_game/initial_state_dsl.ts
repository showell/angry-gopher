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

import { type Card, cardLabel } from "../core/card.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { parseBoardStackLine } from "../dsl/parse.ts";


interface GameStateForDsl {
  readonly board: readonly BoardStack[];
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

function formatBoardBlock(board: readonly BoardStack[]): string {
  const body = board.map(formatBoardLine).join("\n");
  return body === "" ? "board:" : "board:\n" + body;
}

function formatBoardLine(stack: BoardStack): string {
  return "  at ("
    + padCoord(stack.loc.left)
    + ", "
    + padCoord(stack.loc.top)
    + "): "
    + stack.cards.map(cardLabel).join(" ");
}

function padCoord(n: number): string {
  return String(n).padStart(3, " ");
}


// --- HANDS -----------------------------------------------------------

// Mirror of the Elm hand-view's suit-row layout: one row per
// non-empty suit, suits in UI order (Heart, Spade, Diamond,
// Club), cards within a row sorted ascending by value.

const SUIT_DISPLAY_ORDER: readonly number[] = [3, 2, 1, 0]; // H, S, D, C

function formatHandBlock(header: string, hand: readonly Card[]): string {
  const rows = sortIntoSuitRows(hand).map(formatHandRow);
  return rows.length === 0 ? header + ":" : header + ":\n" + rows.join("\n");
}

function sortIntoSuitRows(hand: readonly Card[]): (readonly Card[])[] {
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
  return "  " + cards.map(cardLabel).join(" ");
}


// --- DECK + SCALARS --------------------------------------------------

function formatDeckLine(deck: readonly Card[]): string {
  return "deck: " + deck.map(cardLabel).join(" ");
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
 *  `at (left, top): cards` line. */
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
      out.push(parseBoardStackLine(trimmed));
    }
  }
  return out;
}
