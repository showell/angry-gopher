import type { Card } from "../src/rules/card.ts";
import type { Buckets, RawBuckets } from "../src/buckets.ts";
import { classifyBuckets } from "../src/buckets.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { findPlay, findPlanForBuckets, type PlayResult } from "../src/hand_play.ts";
import { describe, type Desc } from "../src/move.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import type { PlayStep } from "./step_types.ts";
import { cardKey } from "./board.ts";

export function tryPlay(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
): { step: PlayStep; board: readonly (readonly Card[])[]; hand: readonly Card[] } | null {
  if (hand.length === 0) return null;

  const play = findPlay(hand, board);
  if (play === null) return null;

  const next = applyPlay(board, hand, play);
  if (next === null) {
    // findPlay and applyPlay both go through solveStateWithDescs;
    // disagreement on solvability for the same augmented state means
    // the solver is non-deterministic. Surface, don't paper over.
    throw new Error(
      `[play tryPlay] applyPlay returned null for a play findPlay just produced. `
      + `Placements: [${play.placements.map(cardKey).join(" ")}]. `
      + `Plan length: ${play.plan.length}.`,
    );
  }
  return {
    step: {
      kind: "play",
      placements: [...play.placements],
      planDescs: next.planDescs,
    },
    board: next.board,
    hand: next.hand,
  };
}

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
