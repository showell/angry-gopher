// play.ts — play step kind. Owns the planner round-trip
// (findPlay → applyPlay) and the per-play step construction. The
// step shape itself (PlayStep) lives in step_types.ts.
//
// A "play" places ≥1 hand card on the board and leaves the board
// clean (every stack a length-3+ legal kind). The solver
// (engine_v2 via findPlay) proves a clean plan exists; applyPlay
// replays the plan to derive the post-play board and hand.
//
// Throws on internal contradiction: if findPlay produces a play but
// applyPlay's engine call refuses to replay it, two solver
// invocations disagreed on solvability — surface loud, don't paper
// over.

import type { Card } from "../src/rules/card.ts";
import type { Buckets, RawBuckets } from "../src/buckets.ts";
import { classifyBuckets } from "../src/buckets.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { findPlay, findPlanForBuckets, type PlayResult } from "../src/hand_play.ts";
import { describe, type Desc } from "../src/move.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import type { PlayStep } from "./step_types.ts";
import { cardKey } from "./board.ts";

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

/** Apply one play (the move-sequence findPlay returned) to (board, hand).
 *  Returns the post-play state, or null if the engine can't replay
 *  (which shouldn't happen — findPlay already proved a clean-board
 *  plan exists). */
function applyPlay(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  play: PlayResult,
): { board: readonly (readonly Card[])[]; hand: readonly Card[]; planDescs: readonly Desc[] } | null {
  const { helper, trouble } = partition([...board, [...play.placements]]);
  const initial: RawBuckets = { helper, trouble, growing: [], complete: [] };
  const classified = classifyBuckets(initial);

  const plan = findPlanForBuckets(classified);
  if (plan === null) return null;

  const final = applyPlan(classified, plan);

  const newBoard: (readonly Card[])[] = [
    ...final.helper.map(s => [...s.cards] as readonly Card[]),
    ...final.complete.map(s => [...s.cards] as readonly Card[]),
  ];
  const placedSet = new Set(play.placements.map(cardKey));
  const newHand = hand.filter(c => !placedSet.has(cardKey(c)));
  return { board: newBoard, hand: newHand, planDescs: plan.map(p => p.desc) };
}

/** Probe for a playable hand card and replay the resulting plan.
 *  Returns the `PlayStep` plus the post-play (board, hand) if a
 *  play is available; returns `null` when the hand is empty or the
 *  solver finds nothing playable.
 *
 *  `tStart` is the timestamp at which the dispatcher (`fullStep`)
 *  started its step decision. PlayStep.wallMs measures from there
 *  through the end of applyPlay, so it includes any failed groom
 *  probe — i.e., what a human watching the agent perceives as
 *  "agent thinking…" between primitives. */
export function tryPlay(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  tStart: number,
): { step: PlayStep; board: readonly (readonly Card[])[]; hand: readonly Card[] } | null {
  if (hand.length === 0) return null;

  const t0 = performance.now();
  const play = findPlay(hand, board);
  const findPlayMs = performance.now() - t0;
  if (play === null) return null;

  const t1 = performance.now();
  const next = applyPlay(board, hand, play);
  const applyMs = performance.now() - t1;
  if (next === null) {
    // findPlay produced this play (proving a clean-board plan
    // exists), but applyPlay's engine call returned null. Two
    // solver invocations on the same augmented state disagreed on
    // solvability. Don't paper over; surface.
    throw new Error(
      `[play tryPlay] applyPlay returned null for a play findPlay just produced. `
      + `This indicates a divergence between findPlay's engine call and applyPlay's `
      + `(both go through solveStateWithDescs). Placements: [${play.placements.map(cardKey).join(" ")}]. `
      + `Plan length: ${play.plan.length}.`,
    );
  }
  return {
    step: {
      kind: "play",
      placements: [...play.placements],
      planDescs: next.planDescs,
      findPlayMs,
      applyMs,
      wallMs: performance.now() - tStart,
    },
    board: next.board,
    hand: next.hand,
  };
}
