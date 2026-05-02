// hand_play.ts — hand-aware "what should I play?" outer loop.
//
// TS port of python/agent_prelude.py. The BFS engine itself is hand-
// blind — it sees only the 4-bucket board state. This module is the
// hand-aware wrapper: given a hand + a board, find a plausible play
// (which hand cards to place onto the board, plus the BFS plan that
// cleans up the board afterward).
//
// Search order (encodes game preference; no scoring layer):
//
//   (a) For each meldable hand pair, try to find a completing third
//       in the hand → 3 cards leave the hand in one move, no BFS
//       needed. First success returns.
//   (b) For each meldable hand pair without a third, project as a
//       2-partial trouble + run BFS. Collect candidates.
//   (c) For each remaining hand card, project as a singleton trouble
//       + run BFS. Collect candidates.
//   (d) Return the candidate with the shortest plan, or null.
//
// **Dirty-board constraint** (`tryProjection`): when projecting a
// candidate (singleton or pair) onto the board, BFS must clear ALL
// trouble — not just the newly placed cards. The augmented board is
// `board + extraStacks`; classify every stack; HELPER stacks pass
// through; everything else (pre-existing partials AND the newly
// placed cards) goes into TROUBLE; BFS gets `(helper, trouble, [],
// [])` and must produce a plan that resolves the entire trouble
// bucket. If it can't, the placement is rejected. The agent is not
// allowed to leave the board dirtier than it found it.
//
// See `python/SOLVER.md § "Hint projection — how find_play uses BFS
// for hand cards"` for the canonical write-up.

import type { Card } from "./rules/card.ts";
import { cardLabel } from "./rules/card.ts";
import { isPartialOk } from "./rules/stack_type.ts";
import { classifyStack } from "./classified_card_stack.ts";
import type { RawBuckets } from "./buckets.ts";
import { solveStateWithDescs } from "./bfs.ts";

// Default BFS state budget per projection. Mirrors python
// `_PROJECTION_MAX_STATES`. Lowered from 200000 → 5000 in Python on
// 2026-04-25 after the doomed-third + state-level doomed-growing
// filters landed; the TS port doesn't have those filters yet (see
// PORT_STATUS.md "card-tracker liveness pruning"), but the corpus
// scenarios solve cheaply enough that 5000 is sufficient.
const PROJECTION_MAX_STATES = 5000;

export interface PlayResult {
  readonly placements: readonly Card[];
  readonly plan: readonly string[];
}

/**
 * Find a plausible play given a hand and a board. Returns
 * `{ placements, plan }` or `null`.
 *
 * `hand` is a list of card tuples. `board` is a list of stacks, each
 * a list of card tuples. Mirrors python `agent_prelude.find_play`.
 */
export function findPlay(
  hand: readonly Card[],
  board: readonly (readonly Card[])[],
): PlayResult | null {
  // (a) Triple in hand — always 0 BFS steps, best possible.
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      const c1 = hand[i]!;
      const c2 = hand[j]!;
      if (!isPartialOk([c1, c2])) continue;
      const ordered = findCompletingThird([c1, c2], hand, i, j);
      if (ordered !== null) {
        return { placements: ordered, plan: [] };
      }
    }
  }

  // Collect all solvable pair + singleton candidates, then return
  // the one with the shortest plan (easiest for human).
  const candidates: PlayResult[] = [];

  // (b) Pair projections.
  for (let i = 0; i < hand.length; i++) {
    for (let j = i + 1; j < hand.length; j++) {
      const c1 = hand[i]!;
      const c2 = hand[j]!;
      if (!isPartialOk([c1, c2])) continue;
      const plan = tryProjection(board, [[c1, c2]]);
      if (plan !== null) {
        candidates.push({ placements: [c1, c2], plan });
      }
    }
  }

  // (c) Singleton projections.
  for (const c of hand) {
    const plan = tryProjection(board, [[c]]);
    if (plan !== null) {
      candidates.push({ placements: [c], plan });
    }
  }

  if (candidates.length === 0) return null;
  return candidates.reduce((best, cur) =>
    cur.plan.length < best.plan.length ? cur : best,
  );
}

/**
 * Try every position-permutation of (pair + a third hand card)
 * that classifies as a length-3 legal group. Returns the ordered
 * triple, or null. The order matters — runs are consecutive-by-
 * value, so the harness needs to lay the cards down in the legal
 * order. Mirrors python `_find_completing_third`.
 *
 * `pairI`, `pairJ` are the indices of the pair in the hand (so the
 * search skips them rather than relying on object-identity reference
 * equality, which doesn't apply to value-typed Card tuples).
 */
function findCompletingThird(
  pair: readonly [Card, Card],
  hand: readonly Card[],
  pairI: number,
  pairJ: number,
): readonly Card[] | null {
  for (let k = 0; k < hand.length; k++) {
    if (k === pairI || k === pairJ) continue;
    const c = hand[k]!;
    // Skip if c is value-equal to either pair card (matches python's
    // post-identity equality skip — pair cards may be re-encountered
    // as separate value-equal entries in a duplicate-deck hand).
    if (cardEq(c, pair[0]) || cardEq(c, pair[1])) continue;
    const triples: readonly Card[][] = [
      [pair[0], pair[1], c],
      [pair[0], c, pair[1]],
      [c, pair[0], pair[1]],
    ];
    for (const ordered of triples) {
      const ccs = classifyStack(ordered);
      if (ccs !== null && ccs.n >= 3) return ordered;
    }
  }
  return null;
}

function cardEq(a: Card, b: Card): boolean {
  return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
}

/**
 * Project `extraStacks` onto `board`, partition into helper / trouble
 * by classification, run BFS with desc tracking. Returns the plan as
 * a string list, or null if no plan within the projection budget.
 * Mirrors python `_try_projection`.
 *
 * The dirty-board constraint applies: BFS must clean every non-
 * helper stack on the augmented board, not just the projected
 * extras. This is enforced by partition + BFS termination on
 * is_victory (empty trouble + every growing.n >= 3).
 */
function tryProjection(
  board: readonly (readonly Card[])[],
  extraStacks: readonly (readonly Card[])[],
): readonly string[] | null {
  const augmented: (readonly Card[])[] = [...board, ...extraStacks];
  const helper: (readonly Card[])[] = [];
  const trouble: (readonly Card[])[] = [];
  for (const s of augmented) {
    const ccs = classifyStack(s);
    if (ccs === null || ccs.n < 3) {
      trouble.push(s);
    } else {
      helper.push(s);
    }
  }
  const initial: RawBuckets = {
    helper,
    trouble,
    growing: [],
    complete: [],
  };
  const plan = solveStateWithDescs(initial, {
    maxTroubleOuter: 10,
    maxStates: PROJECTION_MAX_STATES,
  });
  if (plan === null) return null;
  return plan.map(p => p.line);
}

/**
 * Render a PlayResult as a [string] step list for display and DSL
 * conformance. Step 0 is always "place [<cards>] from hand"; the
 * remaining steps are the BFS plan-line strings.
 *
 * Returns [] when result is null (stuck — no playable card found).
 * Mirrors python `agent_prelude.format_hint`.
 */
export function formatHint(result: PlayResult | null): readonly string[] {
  if (result === null) return [];
  const labels = result.placements.map(cardLabel).join(" ");
  return [`place [${labels}] from hand`, ...result.plan];
}
