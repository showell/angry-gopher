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
// The dirty-board constraint above is the canonical write-up; no
// external reference is needed.

import type { Card } from "./rules/card.ts";
import { cardLabel } from "./rules/card.ts";
import { isPartialOk } from "./rules/stack_type.ts";
import {
  classifyStack,
  KIND_RUN,
  KIND_RB,
  KIND_SET,
} from "../bfs/classified_card_stack.ts";
import type { Buckets, RawBuckets } from "../bfs/buckets.ts";
import { solveStateWithDescs } from "../bfs/engine_v2.ts";
import { solveBoard, type SolveResult } from "../bfs/index.ts";
import type { Desc } from "../bfs/move.ts";

// Default BFS state budget per projection. Mirrors python
// `_PROJECTION_MAX_STATES`. Lowered from 200000 → 5000 in Python on
// 2026-04-25 after the doomed-third + state-level doomed-growing
// filters landed; ported to TS as the card_neighbors liveness prune
// (2026-05-03), so 5000 is now a comfortable ceiling.
const PROJECTION_MAX_STATES = 5000;

// Plan-length cap.
//
// 2026-05-05: bumped 4 → 5 after the seed-42 turn-10/11 stuck-state
// experiments. At depth 4 the engine gave up on tantalizing boards
// where a 5-verb plan exists (concrete cases: agent-only self-play
// turns 10 and 11 of seed 42); at depth 10 it solved both in 1–2s.
// Depth 5 is the smallest bump that recovers expert-tenacity plays
// while keeping the BFS branching tractable. Within reach of an
// engaged human who's willing to think; well past the give-up
// point of a casual player.
const HINT_MAX_PLAN_LENGTH = 5;

// Outer-trouble pre-flight reject. Boards with more than this
// many trouble cards are presumed unsolvable.
const HINT_MAX_TROUBLE_OUTER = 10;


// Hint-quality solver options. The live hint path (tryProjection)
// and the conformance test harness (findPlanForBuckets) both apply
// these so the two paths can't drift on what "a hint" means.
const HINT_OPTS = {
  maxTroubleOuter: HINT_MAX_TROUBLE_OUTER,
  maxPlanLength: HINT_MAX_PLAN_LENGTH,
} as const;

/** Bucket-level entry used by the conformance harness (scenarios pin
 *  specific helper/trouble/growing/complete layouts). Production code
 *  goes through `solveBoard` instead. */
export function findPlanForBuckets(
  initial: RawBuckets | Buckets,
  maxStates: number = PROJECTION_MAX_STATES,
): SolveResult | null {
  return solveStateWithDescs(initial, { ...HINT_OPTS, maxStates });
}

export interface PlayResult {
  readonly placements: readonly Card[];
  /** Plan-line strings, for hint display + DSL conformance. */
  readonly plan: readonly string[];
  /** Plan descs — same plan, structured form. Transcript writers
   *  feed these to `physicalPlan` to expand into wire primitives. */
  readonly planDescs: readonly Desc[];
  /** The board after the placements + plan are applied. Derived
   *  from the solver's final buckets so consumers don't re-solve. */
  readonly newBoard: readonly (readonly Card[])[];
}

function bucketsToBoard(b: Buckets): readonly (readonly Card[])[] {
  return [
    ...b.helper.map(s => [...s.cards] as readonly Card[]),
    ...b.complete.map(s => [...s.cards] as readonly Card[]),
  ];
}

export interface ProjectionRecord {
  readonly kind: "pair" | "singleton";
  readonly cards: readonly Card[];
  readonly wallMs: number;
  readonly foundPlan: boolean;
}

export interface PlayStats {
  totalWallMs: number;
  projections: ProjectionRecord[];
}

export interface PlayOptions {
  readonly maxStates?: number;
  readonly stats?: PlayStats;
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
  opts: PlayOptions = {},
): PlayResult | null {
  const maxStates = opts.maxStates ?? PROJECTION_MAX_STATES;
  const stats = opts.stats;
  const tStart = performance.now();

  // (a) Triple in hand — short-circuit ONLY when the existing
  //     board is already fully clean (every stack a length-3+
  //     legal group). On a dirty board, recommending "place this
  //     triple from hand" leaves the pre-existing trouble
  //     unaddressed, violating the dirty-board contract. Falling
  //     through routes the triple through tier (b)/(c) projection
  //     where BFS verifies the augmented board reaches victory.
  if (boardIsAllHelper(board)) {
    for (let i = 0; i < hand.length; i++) {
      for (let j = i + 1; j < hand.length; j++) {
        const c1 = hand[i]!;
        const c2 = hand[j]!;
        if (!isPartialOk([c1, c2])) continue;
        const ordered = findCompletingThird([c1, c2], hand, i, j);
        if (ordered !== null) {
          finishStats(stats, tStart);
          // Board was already clean; the new triple is itself a
          // legal length-3+ group (findCompletingThird checked).
          // No plan needed: post-play board = existing helpers + new stack.
          return {
            placements: ordered,
            plan: [],
            planDescs: [],
            newBoard: [...board, ordered],
          };
        }
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
      const proj = tryProjection(board, [[c1, c2]], maxStates, stats, "pair");
      if (proj !== null) {
        candidates.push({ placements: [c1, c2], ...proj });
      }
    }
  }

  // (c) Singleton projections.
  for (const c of hand) {
    const proj = tryProjection(board, [[c]], maxStates, stats, "singleton");
    if (proj !== null) {
      candidates.push({ placements: [c], ...proj });
    }
  }

  finishStats(stats, tStart);
  if (candidates.length === 0) return null;
  const chosen = candidates.reduce((best, cur) =>
    cur.plan.length < best.plan.length ? cur : best,
  );
  return validatesCleanFinish(board, chosen) ? chosen : null;
}

/** Defensive backstop: a hint only counts if it leaves the board
 *  fully clean. BFS-derived plans (tier b/c) are already verified
 *  via `is_victory` at engine termination, but tier (a) and any
 *  future short-circuit path could in principle slip through.
 *  Catches them all in one place: an empty-plan candidate is only
 *  valid when the existing board is already clean AND the
 *  placements form a length-3+ legal group on their own. */
function validatesCleanFinish(
  board: readonly (readonly Card[])[],
  result: PlayResult,
): boolean {
  if (result.plan.length > 0) return true;
  if (!boardIsAllHelper(board)) return false;
  const ccs = classifyStack(result.placements);
  if (ccs === null) return false;
  if (ccs.n < 3) return false;
  return ccs.kind === KIND_RUN || ccs.kind === KIND_RB || ccs.kind === KIND_SET;
}

/** True iff every stack on the board is a length-3+ legal group
 *  (run / rb / set). Pre-existing partials, singletons, or
 *  unclassifiable stacks all count as "dirty." */
function boardIsAllHelper(
  board: readonly (readonly Card[])[],
): boolean {
  for (const stack of board) {
    const ccs = classifyStack(stack);
    if (ccs === null) return false;
    if (ccs.n < 3) return false;
    if (ccs.kind !== KIND_RUN && ccs.kind !== KIND_RB && ccs.kind !== KIND_SET) {
      return false;
    }
  }
  return true;
}

function finishStats(stats: PlayStats | undefined, tStart: number): void {
  if (stats !== undefined) {
    stats.totalWallMs = performance.now() - tStart;
  }
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
interface ProjectionOutcome {
  readonly plan: readonly string[];
  readonly planDescs: readonly Desc[];
  readonly newBoard: readonly (readonly Card[])[];
}

function tryProjection(
  board: readonly (readonly Card[])[],
  extraStacks: readonly (readonly Card[])[],
  maxStates: number,
  stats: PlayStats | undefined,
  kind: "pair" | "singleton",
): ProjectionOutcome | null {
  const augmented: (readonly Card[])[] = [...board, ...extraStacks];
  const cards: Card[] = [];
  for (const s of extraStacks) for (const c of s) cards.push(c);

  const t0 = performance.now();
  const result = solveBoard(augmented, { ...HINT_OPTS, maxStates });
  if (stats !== undefined) {
    stats.projections.push({
      kind,
      cards,
      wallMs: performance.now() - t0,
      foundPlan: result !== null,
    });
  }
  if (result === null) return null;
  return {
    plan: result.plan.map(p => p.line),
    planDescs: result.plan.map(p => p.desc),
    newBoard: bucketsToBoard(result.finalBuckets),
  };
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
