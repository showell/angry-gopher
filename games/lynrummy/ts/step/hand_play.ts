// hand_play.ts — hand-aware "what should I play?" outer loop.
//
// The BFS engine is hand-blind: it sees only the board. This module
// wraps it. Given a hand + a board, find a play (cards to lay onto
// the board + a BFS plan that cleans the augmented board to victory).
//
// Dirty-board contract: BFS-derived plans clear ALL trouble on the
// augmented board (existing partials + new placements), not just the
// new placement. solveBoard's victory check enforces this.

import type { Card } from "../core/card.ts";
import { cardLabel } from "../core/card.ts";
import { isPartialOk, isCompleteGroup } from "../core/card_stack.ts";
import type { Buckets } from "../bfs/buckets.ts";
import { solveBoard } from "../bfs/engine_v2.ts";
import type { Move } from "../bfs/move.ts";

export interface PlayResult {
  readonly cardsToPlay: readonly Card[];
  readonly moves: readonly Move[];
  readonly moveLines: readonly string[];
  readonly newBoard: readonly (readonly Card[])[];
}

interface MeldablePair {
  readonly card1: Card;
  readonly card2: Card;
}

export function findPlay(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): PlayResult | null {
  const meldable = collectMeldablePairs(hand);

  if (boardIsClean(board)) {
    const triple = findTripleInHand(meldable, hand);
    if (triple !== null) {
      return {
        cardsToPlay: triple,
        moves: [],
        moveLines: [],
        newBoard: [...board, triple],
      };
    }
  }

  const candidates = collectProjectionCandidates(meldable, hand, board);
  return candidates.length === 0 ? null : shortestPlan(candidates);
}

export function formatHint(result: PlayResult | null): readonly string[] {
  if (result === null) return [];
  const labels = result.cardsToPlay.map(cardLabel).join(" ");
  return [`place [${labels}] from hand`, ...result.moveLines];
}

// --- Pair collection ----------------------------------------------------

/** Each hand-position pair (i < j) is tried in both orientations;
 *  whichever passes isPartialOk is the canonical one. The wrap pair
 *  K-A is canonical even though rank(K)=13 > rank(A)=1 numerically. */
function collectMeldablePairs(hand: readonly Card[]): readonly MeldablePair[] {
  const out: MeldablePair[] = [];
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      const a = hand[i]!;
      const b = hand[j]!;
      if (isPartialOk([a, b])) out.push({ card1: a, card2: b });
      else if (isPartialOk([b, a])) out.push({ card1: b, card2: a });
    }
  }
  return out;
}

// --- Phase 1: triple-in-hand --------------------------------------------

function findTripleInHand(
  meldable: readonly MeldablePair[],
  hand: readonly Card[],
): readonly Card[] | null {
  for (const { card1, card2 } of meldable) {
    for (const c of hand) {
      if (c === card1 || c === card2) continue;
      const triple: readonly Card[] = [card1, card2, c];
      if (isCompleteGroup(triple)) return triple;
    }
  }
  return null;
}

// --- Phase 2 + 3: pair + singleton projections --------------------------

function collectProjectionCandidates(
  meldable: readonly MeldablePair[],
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): PlayResult[] {
  const candidates: PlayResult[] = [];
  for (const { card1, card2 } of meldable) {
    const r = projectAndSolve(board, [card1, card2]);
    if (r !== null) candidates.push(r);
  }
  for (const card of hand) {
    const r = projectAndSolve(board, [card]);
    if (r !== null) candidates.push(r);
  }
  return candidates;
}

function projectAndSolve(
  board: readonly (readonly Card[])[],
  cardsToPlay: readonly Card[],
): PlayResult | null {
  const augmented: (readonly Card[])[] = [...board, cardsToPlay];
  const result = solveBoard(augmented);
  if (result === null) return null;
  return {
    cardsToPlay,
    moves: result.plan.map(p => p.move),
    moveLines: result.plan.map(p => p.line),
    newBoard: bucketsToBoard(result.finalBuckets),
  };
}

// --- Shared helpers -----------------------------------------------------

function shortestPlan(candidates: readonly PlayResult[]): PlayResult {
  return candidates.reduce((best, cur) =>
    cur.moves.length < best.moves.length ? cur : best,
  );
}

function boardIsClean(board: readonly (readonly Card[])[]): boolean {
  return board.every(isCompleteGroup);
}

function bucketsToBoard(b: Buckets): readonly (readonly Card[])[] {
  return [
    ...b.helper.map(s => [...s.cards] as readonly Card[]),
    ...b.complete.map(s => [...s.cards] as readonly Card[]),
  ];
}
