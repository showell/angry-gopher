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

interface MeldablePair {
  readonly pair: readonly [Card, Card];
  readonly pairI: number;
  readonly pairJ: number;
}

export function findPlay(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): PlayResult | null {
  const meldable = collectMeldablePairs(hand);

  if (boardIsClean(board)) {
    const triple = findTripleAmongPairs(meldable, hand);
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
  for (const { pair } of meldable) {
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

// --- Pair collection ----------------------------------------------------

/** Walk hand positions i < j; for each pair of cards, record it as a
 *  meldable pair in canonical order (the order that isPartialOk
 *  accepts). Either orientation might pass — A-2 is canonical
 *  ascending, but the wrap pair K-A is also canonical (K is the
 *  predecessor of A under the cycle). */
function collectMeldablePairs(hand: readonly Card[]): readonly MeldablePair[] {
  const out: MeldablePair[] = [];
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      const a = hand[i]!;
      const b = hand[j]!;
      if (isPartialOk([a, b])) {
        out.push({ pair: [a, b], pairI: i, pairJ: j });
      } else if (isPartialOk([b, a])) {
        out.push({ pair: [b, a], pairI: i, pairJ: j });
      }
    }
  }
  return out;
}

// --- Triple-in-hand shortcut --------------------------------------------

/** For each canonical meldable pair (a, b), look for a third hand card
 *  c that extends to the right: [a, b, c] forms a legal length-3
 *  group. Left-extensions don't need a separate check — they emerge
 *  as a *different* meldable pair (e.g., the wrap triple K-A-2 is
 *  discovered via the (K, A) pair, not via (A, 2) trying K-on-left). */
function findTripleAmongPairs(
  meldable: readonly MeldablePair[],
  hand: readonly Card[],
): readonly Card[] | null {
  for (const { pair, pairI, pairJ } of meldable) {
    for (let k = 0; k < hand.length; k++) {
      if (k === pairI || k === pairJ) continue;
      const triple: readonly Card[] = [pair[0], pair[1], hand[k]!];
      if (isCompleteGroup(triple)) return triple;
    }
  }
  return null;
}

// --- Pair + singleton projections ---------------------------------------

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

