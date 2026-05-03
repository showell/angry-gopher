// agent_player.ts — agent self-play loop for Lyn Rummy.
//
// One turn:
//   while hand has cards:
//     play = findPlay(hand, board)
//     if play === null: break               (stuck)
//     apply play → new (board, hand)
//     if hand empty: break                  (cleared)
//
// Turn-end draw rule (per Steve, 2026-05-03):
//   stuck (couldn't make ANY further play):  draw 3
//   played whole hand:                       draw 5
//
// `playFullGame` loops turns until the deck reaches a low-water mark
// (default 10 — past that, gameplay is essentially over and self-play
// stops being informative).
//
// This module is the canonical agent driver in TS. The engine v2 A*
// solver is reached via `findPlay` (hand_play.ts) for hint generation
// and `solveStateWithDescs` (engine_v2.ts) for replaying a chosen play
// to derive the new clean board.

import type { Card } from "./rules/card.ts";
import type { Buckets, RawBuckets } from "./buckets.ts";
import { classifyBuckets } from "./buckets.ts";
import { classifyStack } from "./classified_card_stack.ts";
import { findPlay, type PlayResult } from "./hand_play.ts";
import { solveStateWithDescs, type PlanLine } from "./engine_v2.ts";
import { describe, type Desc } from "./move.ts";
import { enumerateMoves } from "./enumerator.ts";

// --- Plan replay (apply a plan to derive the post-plan Buckets) -----

function applyPlan(initial: Buckets, plan: readonly { desc: Desc }[]): Buckets {
  let state: Buckets = initial;
  for (let step = 0; step < plan.length; step++) {
    const want = describe(plan[step]!.desc);
    let matched: Buckets | null = null;
    for (const [desc, next] of enumerateMoves(state)) {
      if (describe(desc) === want) { matched = next; break; }
    }
    if (matched === null) {
      throw new Error(`step ${step + 1}: enumerator did not yield matching move "${want}"`);
    }
    state = matched;
  }
  return state;
}

// --- One find_play → mutate (board, hand) ---------------------------

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

function partition(
  augmented: readonly (readonly Card[])[],
): { helper: (readonly Card[])[]; trouble: (readonly Card[])[] } {
  const helper: (readonly Card[])[] = [];
  const trouble: (readonly Card[])[] = [];
  for (const stack of augmented) {
    const ccs = classifyStack(stack);
    if (ccs === null || ccs.n < 3) trouble.push(stack);
    else helper.push(stack);
  }
  return { helper, trouble };
}

/** Apply a found play to (board, hand). Returns the post-turn state, or
 *  null if the engine can't replay (which shouldn't happen — findPlay
 *  already proved a clean-board plan exists). */
function applyHandPlay(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  play: PlayResult,
): { board: readonly (readonly Card[])[]; hand: readonly Card[] } | null {
  const { helper, trouble } = partition([...board, [...play.placements]]);
  const initial: RawBuckets = { helper, trouble, growing: [], complete: [] };
  const classified = classifyBuckets(initial);

  const plan = solveStateWithDescs(classified, { maxStates: 50000, maxTroubleOuter: 12 });
  if (plan === null) return null;

  const final = applyPlan(classified, plan);

  const newBoard: (readonly Card[])[] = [
    ...final.helper.map(s => [...s.cards] as readonly Card[]),
    ...final.complete.map(s => [...s.cards] as readonly Card[]),
  ];
  const placedSet = new Set(play.placements.map(cardKey));
  const newHand = hand.filter(c => !placedSet.has(cardKey(c)));
  return { board: newBoard, hand: newHand };
}

// --- One turn ----------------------------------------------------------

export interface TurnResult {
  readonly playsMade: number;
  readonly cardsPlayed: readonly Card[];
  readonly outcome: "hand_empty" | "stuck";
  readonly board: readonly (readonly Card[])[];
  readonly hand: readonly Card[];
  readonly findPlayWallMsTotal: number;
  readonly applyWallMsTotal: number;
}

export function playTurn(
  startBoard: readonly (readonly Card[])[],
  startHand: readonly Card[],
): TurnResult {
  let board = startBoard;
  let hand = startHand;
  const cardsPlayed: Card[] = [];
  let playsMade = 0;
  let findPlayWallMsTotal = 0;
  let applyWallMsTotal = 0;

  while (hand.length > 0) {
    const t0 = performance.now();
    const play = findPlay(hand, board);
    findPlayWallMsTotal += performance.now() - t0;
    if (play === null) {
      return {
        playsMade, cardsPlayed, outcome: "stuck",
        board, hand, findPlayWallMsTotal, applyWallMsTotal,
      };
    }

    const t1 = performance.now();
    const next = applyHandPlay(board, hand, play);
    applyWallMsTotal += performance.now() - t1;
    if (next === null) {
      // Engine couldn't replay a play it just produced; treat as stuck
      // (defensive — should not happen with current code).
      return {
        playsMade, cardsPlayed, outcome: "stuck",
        board, hand, findPlayWallMsTotal, applyWallMsTotal,
      };
    }
    board = next.board;
    hand = next.hand;
    for (const c of play.placements) cardsPlayed.push(c);
    playsMade++;
  }

  return {
    playsMade, cardsPlayed, outcome: "hand_empty",
    board, hand, findPlayWallMsTotal, applyWallMsTotal,
  };
}

// --- Full game loop ----------------------------------------------------

export interface GameTurnRecord {
  readonly turnNum: number;
  readonly handBefore: number;
  readonly boardBefore: number;
  readonly playsMade: number;
  readonly cardsPlayedThisTurn: number;
  readonly outcome: "hand_empty" | "stuck";
  readonly cardsDrawn: number;
  readonly handAfter: number;
  readonly boardAfter: number;
  readonly deckRemaining: number;
  readonly turnWallMs: number;
  readonly findPlayWallMsTotal: number;
}

export interface GameResult {
  readonly turns: readonly GameTurnRecord[];
  readonly finalBoard: readonly (readonly Card[])[];
  readonly finalHand: readonly Card[];
  readonly finalDeckSize: number;
  readonly stoppedReason: "deck_low" | "max_turns" | "hand_and_deck_empty";
  readonly totalWallMs: number;
}

export interface PlayGameOptions {
  readonly stopAtDeck?: number;
  readonly maxTurns?: number;
}

export function playFullGame(
  initialBoard: readonly (readonly Card[])[],
  initialHand: readonly Card[],
  initialDeck: readonly Card[],
  opts: PlayGameOptions = {},
): GameResult {
  const stopAtDeck = opts.stopAtDeck ?? 10;
  const maxTurns = opts.maxTurns ?? 100;

  let board = initialBoard;
  let hand = initialHand;
  let deck = [...initialDeck];
  const turns: GameTurnRecord[] = [];
  const tStart = performance.now();
  let stoppedReason: GameResult["stoppedReason"] = "max_turns";

  for (let turnNum = 1; turnNum <= maxTurns; turnNum++) {
    const handBefore = hand.length;
    const boardBefore = board.length;
    const tTurn0 = performance.now();
    const turn = playTurn(board, hand);
    const turnWallMs = performance.now() - tTurn0;

    board = turn.board;
    hand = turn.hand;

    const drawAmount = turn.outcome === "hand_empty" ? 5 : 3;
    const cardsDrawn = Math.min(drawAmount, deck.length);
    if (cardsDrawn > 0) {
      hand = [...hand, ...deck.slice(0, cardsDrawn)];
      deck = deck.slice(cardsDrawn);
    }

    turns.push({
      turnNum,
      handBefore,
      boardBefore,
      playsMade: turn.playsMade,
      cardsPlayedThisTurn: turn.cardsPlayed.length,
      outcome: turn.outcome,
      cardsDrawn,
      handAfter: hand.length,
      boardAfter: board.length,
      deckRemaining: deck.length,
      turnWallMs,
      findPlayWallMsTotal: turn.findPlayWallMsTotal,
    });

    if (deck.length <= stopAtDeck) {
      stoppedReason = "deck_low";
      break;
    }
    if (hand.length === 0 && deck.length === 0) {
      stoppedReason = "hand_and_deck_empty";
      break;
    }
  }

  return {
    turns,
    finalBoard: board,
    finalHand: hand,
    finalDeckSize: deck.length,
    stoppedReason,
    totalWallMs: performance.now() - tStart,
  };
}
