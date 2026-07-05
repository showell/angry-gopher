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
import { solveBoard } from "../bfs/engine_v2.ts";
import { describe, type Move } from "../bfs/move.ts";
import { compressHint } from "./hint_compress.ts";

export interface LogicalMovesForPlay {
  readonly cardsToPlay: readonly Card[];
  readonly moves: readonly Move[];
  readonly moveLines: readonly string[];
}

interface MeldablePair {
  readonly card1: Card;
  readonly card2: Card;
}

export function findLogicalMovesForPlay(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
  handLonerPlaced: boolean,
): LogicalMovesForPlay | null {
  // A hand-origin loner was just laid onto an empty spot. Try to finish the
  // board with NO new projection first — the player's unfinished business is
  // that loner, and opening a new front (projecting more hand cards) is what
  // produced the bundled, over-complex hints. Cheapest first: wholesale
  // merges (whole stacks that simply join — what a human sees before
  // anything merits the word "solve"), then the board-only BFS. The
  // dirty-board contract makes solveBoard fail unless EVERY stack (the
  // loner included) ends legal, so a board-only success is a genuine
  // self-contained completion. On failure we fall through to projection
  // (today's behavior) — non-regressive.
  if (handLonerPlaced) {
    const wholesale = wholesaleMergePlay(board);
    if (wholesale !== null) return wholesale;
    const boardOnly = boardOnlyPlay(board);
    if (boardOnly !== null) return boardOnly;
  }

  const meldable = collectMeldablePairs(hand);

  if (boardIsClean(board)) {
    const triple = findTripleInHand(meldable, hand);
    if (triple !== null) {
      return {
        cardsToPlay: triple,
        moves: [],
        moveLines: [],
      };
    }
  }

  // Prefer singletons over pairs absolutely, irrespective of plan
  // length. Singletons read more naturally as a "play" (one card
  // placed) and give the player more remaining-hand flexibility for
  // the next play. Falling back to pairs only when no singleton
  // works also skips the expensive pair-BFS calls that dominate
  // late-game turns (see random354.md — seed 42 turn 11 drill).
  const singletons = collectSingletonCandidates(hand, board);
  if (singletons.length > 0) return shortestPlan(singletons);

  const pairs = collectPairCandidates(meldable, board);
  if (pairs.length > 0) return shortestPlan(pairs);

  return null;
}

export function formatHint(result: LogicalMovesForPlay | null): readonly string[] {
  if (result === null) return [];
  // A board-only finish (loner completed with board cards) plays no new card,
  // so there is no "place … from hand" line — just the board moves.
  const lines = result.cardsToPlay.length === 0
    ? [...result.moveLines]
    : [`place [${result.cardsToPlay.map(cardLabel).join(" ")}] from hand`, ...result.moveLines];
  return compressHint(lines);
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

// --- Phase 2: singleton projections (always tried first) ----------------

function collectSingletonCandidates(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): LogicalMovesForPlay[] {
  const candidates: LogicalMovesForPlay[] = [];
  for (const card of hand) {
    const r = projectAndSolve(board, [card]);
    if (r !== null) candidates.push(r);
  }
  return candidates;
}

// --- Phase 3: pair projections (fallback only) --------------------------

function collectPairCandidates(
  meldable: readonly MeldablePair[],
  board: readonly (readonly Card[])[],
): LogicalMovesForPlay[] {
  const candidates: LogicalMovesForPlay[] = [];
  for (const { card1, card2 } of meldable) {
    const r = projectAndSolve(board, [card1, card2]);
    if (r !== null) candidates.push(r);
  }
  return candidates;
}

function projectAndSolve(
  board: readonly (readonly Card[])[],
  cardsToPlay: readonly Card[],
): LogicalMovesForPlay | null {
  const augmented: (readonly Card[])[] = [...board, cardsToPlay];
  const result = solveBoard(augmented);
  if (result === null) return null;
  return {
    cardsToPlay,
    moves: result.plan.map(p => p.move),
    moveLines: result.plan.map(p => p.line),
  };
}

// --- Shared helpers -----------------------------------------------------

function shortestPlan(candidates: readonly LogicalMovesForPlay[]): LogicalMovesForPlay {
  return candidates.reduce((best, cur) =>
    cur.moves.length < best.moves.length ? cur : best,
  );
}

function boardIsClean(board: readonly (readonly Card[])[]): boolean {
  return board.every(isCompleteGroup);
}

/** Wholesale-merge pre-pass: a human looks for whole stacks that simply
 *  join BEFORE anything complicated enough to merit the word "solve" — and
 *  prefers moving the broken thing onto the good structure, never shaving
 *  the good structure to feed the broken thing (which the trouble-greedy
 *  BFS happily does; it found peel-7♥-onto-the-pair where a human pushes
 *  the pair onto the run). Each greedy pass tries trouble+trouble joins
 *  first (fix the broken with the broken — [K♠ A♦] + [2♠] snap into the
 *  wrap run without touching any helper), then incomplete-onto-helper
 *  merges, until nothing joins. Only a fully clean board counts: anything
 *  short returns null and the caller falls through to the solver — never
 *  a half-applied merge list. The merges are genuine Moves rendered via
 *  describe(), so the line format has one authority and flows through
 *  compressHint like any solver plan. */
function wholesaleMergePlay(
  board: readonly (readonly Card[])[],
): LogicalMovesForPlay | null {
  const stacks: (readonly Card[])[] = [...board];
  const moves: Move[] = [];
  while (troubleTroubleMerge(stacks, moves) || troubleHelperMerge(stacks, moves)) {
    // greedy fixpoint
  }
  if (moves.length === 0 || !stacks.every(isCompleteGroup)) return null;
  return {
    cardsToPlay: [],
    moves,
    moveLines: moves.map(describe),
  };
}

/** One trouble+trouble join, if any exists: two incomplete stacks whose
 *  concatenation is a COMPLETE group. Board stacks are always legal-or-
 *  partial, so incompletes are length 1–2 and the only completable shape
 *  is single+pair — exactly the engine's free_pull (rendered `pull X onto
 *  [pair]`). Never merges two loose cards into a still-troublesome pair:
 *  they may have been split apart for good board-wide reasons, and only a
 *  COMPLETE result counts. (Pair+pair→4 has no verb and no real case yet;
 *  it stays invisible here and falls to the solver.) */
function troubleTroubleMerge(
  stacks: (readonly Card[])[],
  moves: Move[],
): boolean {
  for (let i = 0; i < stacks.length; i++) {
    const s = stacks[i]!;
    if (s.length !== 1) continue;
    for (let j = 0; j < stacks.length; j++) {
      const t = stacks[j]!;
      if (j === i || t.length !== 2 || isCompleteGroup(t)) continue;
      for (const side of ["right", "left"] as const) {
        const result = side === "right" ? [...t, ...s] : [...s, ...t];
        if (!isCompleteGroup(result)) continue;
        moves.push({
          type: "free_pull",
          loose: s[0]!,
          targetBefore: t,
          targetBucketBefore: "trouble",
          result,
          side,
          graduated: true,
        });
        stacks[j] = result;
        stacks.splice(i, 1);
        return true;
      }
    }
  }
  return false;
}

/** One incomplete-onto-helper join, if any exists: an incomplete stack
 *  whose wholesale concatenation onto a complete group (either end) is
 *  itself complete — the engine's push. */
function troubleHelperMerge(
  stacks: (readonly Card[])[],
  moves: Move[],
): boolean {
  for (let i = 0; i < stacks.length; i++) {
    const s = stacks[i]!;
    if (isCompleteGroup(s)) continue;
    for (let j = 0; j < stacks.length; j++) {
      const t = stacks[j]!;
      if (j === i || !isCompleteGroup(t)) continue;
      for (const side of ["right", "left"] as const) {
        const result = side === "right" ? [...t, ...s] : [...s, ...t];
        if (!isCompleteGroup(result)) continue;
        moves.push({ type: "push", troubleBefore: s, targetBefore: t, result, side });
        stacks[j] = result;
        stacks.splice(i, 1);
        return true;
      }
    }
  }
  return false;
}

/** Try to make the whole board legal using only board→board moves — no new
 *  hand card projected. Returns a play with empty `cardsToPlay`, or null if
 *  the board can't be resolved without a hand card (or is already clean, so
 *  there is nothing to finish). */
function boardOnlyPlay(
  board: readonly (readonly Card[])[],
): LogicalMovesForPlay | null {
  const result = solveBoard(board);
  if (result === null || result.plan.length === 0) return null;
  return {
    cardsToPlay: [],
    moves: result.plan.map(p => p.move),
    moveLines: result.plan.map(p => p.line),
  };
}
