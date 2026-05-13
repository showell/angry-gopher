// Vocabulary (load-bearing across the codebase):
//   Move      — one verb-level step in the BFS's plan (peel, push,
//               splice, …). Lowered to primitives by physicalPlan.
//   Primitive — one wire-level UI action (place_hand, merge_stack,
//               …). Same shape as Elm's GameEvent.
//   play      — placement of ≥1 hand card + the BFS Moves that
//               clean the augmented board. What findPlay returns.
//   turn      — a sequence of plays followed by complete_turn
//               (the draw). One individual player's turn.

import type { Card } from "../src/rules/card.ts";
import type { BoardStack } from "../src/geometry.ts";
import { fullStep } from "./full_step.ts";
import type { TurnStep } from "./step_types.ts";

export interface GameTurnRecord {
  readonly turnNum: number;
  readonly activePlayerIndex: number;
  readonly handBefore: number;
  readonly boardBefore: number;
  readonly playsMade: number;
  readonly cardsPlayedThisTurn: number;
  readonly outcome: "hand_empty" | "stuck";
  readonly drawCount: number;
  readonly cardsDrawn: number;
  readonly handAfter: number;
  readonly boardAfter: number;
  readonly deckRemaining: number;
  readonly steps: readonly TurnStep[];
}

function drawCountFor(outcome: "hand_empty" | "stuck", cardsPlayedThisTurn: number): number {
  if (outcome === "hand_empty") return 5;
  if (cardsPlayedThisTurn === 0) return 3;
  return 0;
}

export function simulateFullTurn(
  startBoard: readonly BoardStack[],
  startHand: readonly Card[],
  startDeck: readonly Card[],
  turnNum: number,
  activePlayerIndex: number,
): {
  board: readonly BoardStack[];
  hand: readonly Card[];
  deck: readonly Card[];
  record: GameTurnRecord;
} {
  const handBefore = startHand.length;
  const boardBefore = startBoard.length;

  let board: readonly BoardStack[] = startBoard;
  let hand = startHand;
  const cardsPlayed: Card[] = [];
  const steps: TurnStep[] = [];
  let playsMade = 0;
  let outcome: "hand_empty" | "stuck";

  while (true) {
    const result = fullStep(board, hand);
    board = result.board;
    hand = result.hand;
    if (result.step.kind === "end") {
      outcome = result.step.outcome;
      break;
    }
    steps.push(result.step);
    if (result.step.kind === "play") {
      for (const c of result.step.placements) cardsPlayed.push(c);
      playsMade++;
    }
  }

  if (handBefore - cardsPlayed.length !== hand.length) {
    throw new Error(
      `[full_turn simulateFullTurn] turn ${turnNum} player ${activePlayerIndex} `
      + `hand arithmetic: handBefore (${handBefore}) - cardsPlayed (${cardsPlayed.length}) `
      + `= ${handBefore - cardsPlayed.length}, expected handAfterPlays ${hand.length}`,
    );
  }

  const drawCount = drawCountFor(outcome, cardsPlayed.length);
  const cardsDrawn = Math.min(drawCount, startDeck.length);
  const handAfterDraw = cardsDrawn > 0
    ? [...hand, ...startDeck.slice(0, cardsDrawn)]
    : hand;
  const newDeck = cardsDrawn > 0 ? startDeck.slice(cardsDrawn) : startDeck;

  const record: GameTurnRecord = {
    turnNum,
    activePlayerIndex,
    handBefore,
    boardBefore,
    playsMade,
    cardsPlayedThisTurn: cardsPlayed.length,
    outcome,
    drawCount,
    cardsDrawn,
    handAfter: handAfterDraw.length,
    boardAfter: board.length,
    deckRemaining: newDeck.length,
    steps,
  };

  return { board, hand: handAfterDraw, deck: newDeck, record };
}
