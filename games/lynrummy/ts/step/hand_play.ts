// hand_play.ts — hand-aware "what should I play?" outer loop.
//
// The BFS engine is hand-blind: it sees only the board. This module
// wraps it. Given a hand + a board, find a play (cards to lay onto
// the board + a BFS plan that cleans the augmented board to victory).
//
// Search order:
//   1. Triple-in-hand shortcut (clean board only): if a hand pair has
//      a completing third in the hand, lay the triple down. No plan
//      needed.
//   2. Pair projections: for each meldable hand pair, place it as a
//      2-partial and ask BFS for a plan that clears the result.
//   3. Singleton projections: same per hand card.
//   4. Among BFS candidates from (2)+(3), pick the shortest plan.
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
  readonly placements: readonly Card[];
  /** The plan as structured Moves — what physicalPlan consumes. */
  readonly plan: readonly Move[];
  /** Same plan as one-line DSL strings, for hint display + conformance. */
  readonly planLines: readonly string[];
  /** Board after placements + plan are applied. Derived from the
   *  solver's final buckets so consumers don't re-solve. */
  readonly newBoard: readonly (readonly Card[])[];
}

export function findPlay(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): PlayResult | null {
  if (boardIsClean(board)) {
    const triple = findTripleInHand(hand);
    if (triple !== null) {
      return {
        placements: triple,
        plan: [],
        planLines: [],
        newBoard: [...board, triple],
      };
    }
  }

  const candidates: PlayResult[] = [];
  for (const pair of meldablePairs(hand)) {
    const r = projectAndSolve(board, pair);
    if (r !== null) candidates.push(r);
  }
  for (const card of hand) {
    const r = projectAndSolve(board, [card]);
    if (r !== null) candidates.push(r);
  }
  return candidates.length === 0 ? null : shortestPlan(candidates);
}

export function formatHint(result: PlayResult | null): readonly string[] {
  if (result === null) return [];
  const labels = result.placements.map(cardLabel).join(" ");
  return [`place [${labels}] from hand`, ...result.planLines];
}

// --- Triple-in-hand shortcut --------------------------------------------

function findTripleInHand(hand: readonly Card[]): readonly Card[] | null {
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      const pair: readonly [Card, Card] = [hand[i]!, hand[j]!];
      if (!isPartialOk(pair)) continue;
      const triple = findCompletingThird(pair, hand, i, j);
      if (triple !== null) return triple;
    }
  }
  return null;
}

/** Try every position-permutation of (pair + a hand card) that lands
 *  a length-3 legal group. Order matters: runs are consecutive-by-
 *  value, so the harness lays the cards in the legal order. */
function findCompletingThird(
  pair: readonly [Card, Card],
  hand: readonly Card[],
  pairI: number,
  pairJ: number,
): readonly Card[] | null {
  for (let k = 0; k < hand.length; k++) {
    if (k === pairI || k === pairJ) continue;
    const c = hand[k]!;
    // Skip value-equal duplicates of either pair card — same card from
    // a different deck slot adds no fresh option.
    if (cardEq(c, pair[0]) || cardEq(c, pair[1])) continue;
    const tries: readonly (readonly Card[])[] = [
      [pair[0], pair[1], c],
      [pair[0], c, pair[1]],
      [c, pair[0], pair[1]],
    ];
    for (const ordered of tries) {
      if (isCompleteGroup(ordered)) return ordered;
    }
  }
  return null;
}

// --- Pair + singleton projections ---------------------------------------

function* meldablePairs(hand: readonly Card[]): Generator<readonly [Card, Card]> {
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      const pair: readonly [Card, Card] = [hand[i]!, hand[j]!];
      if (isPartialOk(pair)) yield pair;
    }
  }
}

function projectAndSolve(
  board: readonly (readonly Card[])[],
  placements: readonly Card[],
): PlayResult | null {
  const augmented: (readonly Card[])[] = [...board, placements];
  const result = solveBoard(augmented);
  if (result === null) return null;
  return {
    placements,
    plan: result.plan.map(p => p.move),
    planLines: result.plan.map(p => p.line),
    newBoard: bucketsToBoard(result.finalBuckets),
  };
}

// --- Shared helpers -----------------------------------------------------

function shortestPlan(candidates: readonly PlayResult[]): PlayResult {
  return candidates.reduce((best, cur) =>
    cur.plan.length < best.plan.length ? cur : best,
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

function cardEq(a: Card, b: Card): boolean {
  return a.rank === b.rank && a.suit === b.suit && a.deck === b.deck;
}
