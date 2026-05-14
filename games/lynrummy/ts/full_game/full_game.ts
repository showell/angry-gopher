import type { Card } from "../core/card.ts";
import type { BoardStack } from "../src/geometry.ts";
import { simulateFullTurn, type GameTurnRecord } from "./full_turn.ts";
import { cardKey } from "../step/board.ts";

export interface GameResult {
  readonly turns: readonly GameTurnRecord[];
  readonly finalBoard: readonly BoardStack[];
  readonly finalHands: readonly (readonly Card[])[];
  readonly finalDeckSize: number;
  readonly stoppedReason: "deck_low" | "max_turns" | "hand_and_deck_empty";
}

// Game-end conditions, hard-coded as a deliberate design decision.
//
//   STOP_AT_DECK — once the draw pile drops to this many cards or
//                  fewer, the game ends. Matches the kitchen-table
//                  "deck is running low, let's wrap up" intuition;
//                  also keeps test runs bounded.
//   MAX_TURNS    — infinite-loop guard. Real games end via STOP_AT_DECK
//                  well before this fires.
const STOP_AT_DECK = 10;
const MAX_TURNS = 200;

export function playFullGame(
  initialBoard: readonly BoardStack[],
  initialHands: readonly (readonly Card[])[],
  initialDeck: readonly Card[],
): GameResult {

  let board: readonly BoardStack[] = initialBoard;
  let hands: readonly (readonly Card[])[] = initialHands.map(h => [...h]);
  let deck: readonly Card[] = [...initialDeck];
  let activePlayerIndex = 0;

  const initialCardKeys = collectCardKeys(
    board,
    ([] as Card[]).concat(...hands),
    deck,
  );

  const turns: GameTurnRecord[] = [];
  let stoppedReason: GameResult["stoppedReason"] = "max_turns";
  let turnNum = 1;

  while (deck.length > STOP_AT_DECK) {
    if (turnNum > MAX_TURNS) break;

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

    assertCardsConserved(
      initialCardKeys,
      board,
      ([] as Card[]).concat(...hands),
      deck,
      `playFullGame turn ${turnNum}`,
    );

    activePlayerIndex = (activePlayerIndex + 1) % hands.length;

    if (allHandsEmpty(hands) && deck.length === 0) {
      stoppedReason = "hand_and_deck_empty";
      break;
    }

    turnNum++;
  }

  if (stoppedReason === "max_turns" && deck.length <= STOP_AT_DECK) {
    stoppedReason = "deck_low";
  }

  return {
    turns,
    finalBoard: board,
    finalHands: hands.map(h => [...h]),
    finalDeckSize: deck.length,
    stoppedReason,
  };
}

function totalCardCount(board: readonly BoardStack[]): number {
  let n = 0;
  for (const s of board) n += s.cards.length;
  return n;
}

function collectCardKeys(
  board: readonly BoardStack[],
  hand: readonly Card[],
  deck: readonly Card[],
): string[] {
  const keys: string[] = [];
  for (const s of board) for (const c of s.cards) keys.push(cardKey(c));
  for (const c of hand) keys.push(cardKey(c));
  for (const c of deck) keys.push(cardKey(c));
  return keys.sort();
}

function assertCardsConserved(
  expected: readonly string[],
  board: readonly BoardStack[],
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
