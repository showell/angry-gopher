// full_turn.ts — one individual player's turn. Main entry:
// `simulateFullTurn`. Drives `fullStep` (see full_step.ts) until the
// step boundary signals "end," then applies the outcome-appropriate
// draw and returns the post-turn (board, hand, deck) plus a
// structured record.
//
// Turn-end draw rule (canonical Lyn Rummy):
//   stuck (couldn't make ANY further play):  draw 3
//   played some, hand non-empty:             draw 0
//   played whole hand:                       draw 5
//
// Vocabulary (load-bearing across the codebase):
//   move  — one primitive UI action (place_hand, merge_stack, …).
//   play  — a sequence of moves that places ≥1 hand card and leaves
//           the board clean. What findPlay returns. What the hint
//           surface displays as one logical "do this."
//   turn  — a sequence of plays followed by the complete-turn event
//           (the draw). One individual player's turn.

import type { Card } from "../src/rules/card.ts";
import { fullStep, type PlayStep, type TurnStep } from "./full_step.ts";

// --- Records ----------------------------------------------------------
//
// A turn is a single ordered list of `steps`. Each step is a
// `GroomStep` (see groom.ts) or a `PlayStep` (see full_step.ts).
// The stream's shape emerges from `fullStep`'s contract:
// groom-when-available wins over play-when-available, and nothing is
// emitted when neither fires. Consumers (transcript writer, puzzle
// capture, the eventual Elm port) walk `steps` in order and dispatch
// on `kind`.

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
  readonly turnWallMs: number;
  readonly findPlayWallMsTotal: number;
  /** The interleaved groom/play stream. `simulateFullTurn` is the
   *  only producer. */
  readonly steps: readonly TurnStep[];
}

/** Compute draw count per the canonical Lyn Rummy rule (matches
 *  Elm `Game.applyValidTurn` drawCount).
 *  - hand emptied → 5
 *  - played zero → 3
 *  - played some, hand non-empty → 0 */
function drawCountFor(outcome: "hand_empty" | "stuck", cardsPlayedThisTurn: number): number {
  if (outcome === "hand_empty") return 5;
  if (cardsPlayedThisTurn === 0) return 3;
  return 0;
}

// --- One full turn ----------------------------------------------------

/** Run one individual player's full turn. Loops `fullStep` until it
 *  returns `end`, then applies the outcome-appropriate draw. Returns
 *  the post-turn (board, hand, deck) plus a structured record.
 *
 *  This is the first-class "one turn" boundary — the eventual
 *  human-watches-agent-as-Player-Two flow will dispatch `fullStep`
 *  call by call rather than running the whole turn through
 *  `simulateFullTurn`, but both surfaces share `fullStep` as the
 *  agent's only step-decision API. */
export function simulateFullTurn(
  startBoard: readonly (readonly Card[])[],
  startHand: readonly Card[],
  startDeck: readonly Card[],
  turnNum: number,
  activePlayerIndex: number,
): {
  board: readonly (readonly Card[])[];
  hand: readonly Card[];
  deck: readonly Card[];
  record: GameTurnRecord;
} {
  const handBefore = startHand.length;
  const boardBefore = startBoard.length;
  const tTurn0 = performance.now();

  // Drive `fullStep` until it returns `end`. Each non-end step is
  // pushed onto the turn's step stream verbatim.
  let board: readonly (readonly Card[])[] = startBoard;
  let hand = startHand;
  const cardsPlayed: Card[] = [];
  const steps: TurnStep[] = [];
  let playsMade = 0;
  let findPlayWallMsTotal = 0;
  let applyWallMsTotal = 0;
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
      const play: PlayStep = result.step;
      findPlayWallMsTotal += play.findPlayMs;
      applyWallMsTotal += play.applyMs;
      for (const c of play.placements) cardsPlayed.push(c);
      playsMade++;
    }
  }

  const turnWallMs = performance.now() - tTurn0;

  // Per-turn invariants.
  if (handBefore - cardsPlayed.length !== hand.length) {
    throw new Error(
      `[full_turn simulateFullTurn] turn ${turnNum} player ${activePlayerIndex} `
      + `hand arithmetic: handBefore (${handBefore}) - cardsPlayed (${cardsPlayed.length}) `
      + `= ${handBefore - cardsPlayed.length}, expected handAfterPlays ${hand.length}`,
    );
  }

  // Draw for the outgoing (active) player.
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
    turnWallMs,
    findPlayWallMsTotal,
    steps,
  };

  // applyWallMsTotal is computed for symmetry with findPlayWallMsTotal
  // but isn't currently surfaced in the record; reference to silence
  // unused-var lints if any tighten later.
  void applyWallMsTotal;

  return { board, hand: handAfterDraw, deck: newDeck, record };
}
