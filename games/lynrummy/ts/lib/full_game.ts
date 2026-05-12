// full_game.ts — multi-hand orchestrator. Main entry: `playFullGame`.
// Tracks hands[] + active-player index, drives one full turn at a
// time via `simulateFullTurn`, advances until the deck runs low.
//
// Lyn Rummy is a TWO-HAND game. "Solo" means one *user* (a human
// playing both sides, or an agent simulating both) — never one hand.
// The dealer rules (per Elm Game.applyValidTurn):
//
//   1. Lay 23-card opening board.
//   2. Deal 15 to Player 1, 15 to Player 2 (51 left in deck).
//   3. Player 0 begins; alternate via active_player_index.
//   4. CompleteTurn → outgoing player draws 0/3/5 based on outcome
//      (see `drawCountFor` in full_turn.ts).
//   5. nextActive = (outgoingIdx + 1) % nHands.
//
// playFullGame mirrors this exactly. Both hands are driven by the
// same agent brain (engine_v2 + findPlay); from a gameplay
// perspective it's solitaire-style self-play, but the wire-format
// shape matches what Elm encodes for "real" 2-player games.

import type { Card } from "../src/rules/card.ts";
import { simulateFullTurn, type GameTurnRecord } from "./full_turn.ts";
import { cardKey } from "./board.ts";

export interface GameResult {
  readonly turns: readonly GameTurnRecord[];
  readonly finalBoard: readonly (readonly Card[])[];
  readonly finalHands: readonly (readonly Card[])[];
  readonly finalDeckSize: number;
  readonly stoppedReason: "deck_low" | "max_turns" | "hand_and_deck_empty";
  readonly totalWallMs: number;
}

export interface PlayGameOptions {
  readonly stopAtDeck?: number;
  readonly maxTurns?: number;
}

// --- Game-level invariant: card conservation -------------------------
//
// Snapshot the initial card multiset; every per-turn check compares the
// live state against it. If the multiset drifts, something deeper than
// one turn has gone wrong — surface loud, don't paper over.

function totalCardCount(board: readonly (readonly Card[])[]): number {
  let n = 0;
  for (const s of board) n += s.length;
  return n;
}

function collectCardKeys(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  deck: readonly Card[],
): string[] {
  const keys: string[] = [];
  for (const s of board) for (const c of s) keys.push(cardKey(c));
  for (const c of hand) keys.push(cardKey(c));
  for (const c of deck) keys.push(cardKey(c));
  return keys.sort();
}

function assertCardsConserved(
  expected: readonly string[],
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  deck: readonly Card[],
  ctx: string,
): void {
  const got = collectCardKeys(board, hand, deck);
  if (got.length !== expected.length) {
    throw new Error(
      `[full_game ${ctx}] card-count drift: expected ${expected.length}, got ${got.length} (board=${totalCardCount(board)} hand=${hand.length} deck=${deck.length})`,
    );
  }
  for (let i = 0; i < got.length; i++) {
    if (got[i] !== expected[i]) {
      throw new Error(
        `[full_game ${ctx}] card-set drift at sorted index ${i}: expected ${expected[i]}, got ${got[i]}`,
      );
    }
  }
}

function allHandsEmpty(hands: readonly (readonly Card[])[]): boolean {
  for (const h of hands) if (h.length > 0) return false;
  return true;
}

export function playFullGame(
  initialBoard: readonly (readonly Card[])[],
  initialHands: readonly (readonly Card[])[],
  initialDeck: readonly Card[],
  opts: PlayGameOptions = {},
): GameResult {
  const stopAtDeck = opts.stopAtDeck ?? 10;
  const maxTurns = opts.maxTurns ?? 200;
  const tStart = performance.now();

  let board: readonly (readonly Card[])[] = initialBoard;
  let hands: readonly (readonly Card[])[] = initialHands.map(h => [...h]);
  let deck: readonly Card[] = [...initialDeck];
  let activePlayerIndex = 0;

  // Card-conservation baseline. Snapshot the initial card multiset
  // once; every per-turn check compares the live state against it.
  const initialCardKeys = collectCardKeys(
    board,
    ([] as Card[]).concat(...hands),
    deck,
  );

  const turns: GameTurnRecord[] = [];
  let stoppedReason: GameResult["stoppedReason"] = "max_turns";
  let turnNum = 1;

  while (deck.length > stopAtDeck) {
    if (turnNum > maxTurns) break;

    const result = simulateFullTurn(
      board,
      hands[activePlayerIndex]!,
      deck,
      turnNum,
      activePlayerIndex,
    );
    board = result.board;
    hands = hands.map((h, i) => i === activePlayerIndex ? result.hand : h);
    deck = result.deck;
    turns.push(result.record);

    // INVARIANT: card conservation across the entire game.
    assertCardsConserved(
      initialCardKeys,
      board,
      ([] as Card[]).concat(...hands),
      deck,
      `playFullGame turn ${turnNum}`,
    );

    // Advance active player. Mirrors Elm's
    // `nextActive = modBy nHands (outgoingIdx + 1)`.
    activePlayerIndex = (activePlayerIndex + 1) % hands.length;

    if (allHandsEmpty(hands) && deck.length === 0) {
      stoppedReason = "hand_and_deck_empty";
      break;
    }

    turnNum++;
  }

  if (stoppedReason === "max_turns" && deck.length <= stopAtDeck) {
    stoppedReason = "deck_low";
  }

  return {
    turns,
    finalBoard: board,
    finalHands: hands.map(h => [...h]),
    finalDeckSize: deck.length,
    stoppedReason,
    totalWallMs: performance.now() - tStart,
  };
}
