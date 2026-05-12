// full_step.ts — one step of an agent's turn. Main entry:
// `fullStep(board, hand)`. Decides what the agent does next:
// groom-when-available, otherwise play-when-available, otherwise end.
// This is the load-bearing boundary for an agent move — the same
// surface a human watching agent-as-Player-Two will dispatch
// against, call by call.
//
// The three step kinds:
//   - GroomStep  (defined in groom.ts) — board cleanup
//   - PlayStep   — one findPlay → applyPlay round-trip
//   - EndStep    — no groom AND no play possible; turn over
//
// FullStep = the two progress kinds (groom or play). EndStep is the
// "no progress" terminator and is not itself a step in the turn's
// stream.

import type { Card } from "../src/rules/card.ts";
import type { Buckets, RawBuckets } from "../src/buckets.ts";
import { classifyBuckets } from "../src/buckets.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "../src/classified_card_stack.ts";
import { findPlay, findPlanForBuckets, type PlayResult } from "../src/hand_play.ts";
import { describe, type Desc } from "../src/move.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import { tryGroom, type GroomStep } from "./groom.ts";

// --- Card-key utility ------------------------------------------------

export function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

// --- Step shapes -----------------------------------------------------

/** One successful findPlay → applyPlay round-trip. */
export interface PlayStep {
  readonly kind: "play";
  readonly placements: readonly Card[];
  readonly planDescs: readonly Desc[];
  readonly findPlayMs: number;
  readonly applyMs: number;
  /** Total wall time the agent spent producing this step,
   *  including the cheap groom probe that came up empty. This is
   *  what the human watching agent-as-Player-Two will perceive
   *  as "agent thinking…" between primitives. */
  readonly wallMs: number;
}

/** Returned by `fullStep` to signal the turn is over (no grooms
 *  available AND no findPlay succeeded, or the hand is empty). */
export interface EndStep {
  readonly kind: "end";
  readonly outcome: "hand_empty" | "stuck";
}

export type TurnStep = GroomStep | PlayStep;

/** One step result, plus the post-step (board, hand). For `end` the
 *  state is unchanged from the inputs; for `groom`/`play` the state
 *  reflects what would be on the board if the step's effects were
 *  applied. */
export interface FullStepResult {
  readonly step: GroomStep | PlayStep | EndStep;
  readonly board: readonly (readonly Card[])[];
  readonly hand: readonly Card[];
}

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

// --- Invariant assertions --------------------------------------------
//
// Per memory/feedback_dont_paper_over_problems.md: invariants are
// permanent (always-on, throw on violation). If `assertBoardClean`
// ever fires, the agent's internal state has diverged from what the
// rules guarantee — every downstream symptom (transcript drift,
// replay confusion, geometry chaos) cascades from here.

/** Every stack on the board must classify as a legal length-3+ kind
 *  (run / rb / set). The BFS guarantee is that every applyPlay
 *  produces a clean board; if this fires, either the BFS was wrong
 *  or applyPlan diverged from solveStateWithDescs. */
function assertBoardClean(
  board: readonly (readonly Card[])[],
  ctx: string,
): void {
  for (let i = 0; i < board.length; i++) {
    const stack = board[i]!;
    const ccs: ClassifiedCardStack | null = classifyStack(stack);
    if (ccs === null) {
      throw new Error(
        `[full_step ${ctx}] stack ${i} failed to classify: [${stack.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.n < 3) {
      throw new Error(
        `[full_step ${ctx}] stack ${i} length ${ccs.n} (${ccs.kind}) — not graduated: [${stack.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.kind !== "run" && ccs.kind !== "rb" && ccs.kind !== "set") {
      throw new Error(
        `[full_step ${ctx}] stack ${i} kind ${ccs.kind} not a length-3+ legal kind: [${stack.map(cardKey).join(" ")}]`,
      );
    }
  }
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

// --- fullStep: the agent's per-step boundary -------------------------
//
// `fullStep(board, hand)` is the agent's primary contract. The caller
// (a self-play loop, or eventually an Elm port) calls it repeatedly;
// each call returns one of:
//
//   - `groom` — a non-empty batch of run-merges to animate
//   - `play`  — one findPlay→applyPlay round-trip with placements
//   - `end`   — no groom available AND no play available; turn over
//
// The contract is "groom-first when available, play-when-not, end-
// when-neither." Both sides of the alternation fall out naturally:
// after a play that opens a board-level join, the next call returns
// the groom; once grooms are exhausted, the next call returns a
// play; when nothing else is possible, the next call returns end.
//
// Empty grooms are NEVER returned — if `tryGroom` returns null, we
// silently fall through to findPlay. The caller's loop stays tight:
// dispatch on kind, animate, call again.

export function fullStep(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
): FullStepResult {
  const tStart = performance.now();
  // 1. Groom-first. Delegates to groom.ts; nothing groom-shaped
  //    leaks back here beyond the step + new board.
  const groomed = tryGroom(board);
  if (groomed !== null) {
    assertBoardClean(groomed.board, "fullStep after-groom");
    return { step: groomed.step, board: groomed.board, hand };
  }

  // 2. End if hand is empty.
  if (hand.length === 0) {
    return { step: { kind: "end", outcome: "hand_empty" }, board, hand };
  }

  // 3. Try a play.
  const t0 = performance.now();
  const play = findPlay(hand, board);
  const findPlayMs = performance.now() - t0;
  if (play === null) {
    return { step: { kind: "end", outcome: "stuck" }, board, hand };
  }

  const t1 = performance.now();
  const next = applyPlay(board, hand, play);
  const applyMs = performance.now() - t1;
  if (next === null) {
    // findPlay produced this play (proving a clean-board plan
    // exists), but applyPlay's engine call returned null. That's a
    // contradiction — two engine invocations on the same augmented
    // state disagreed on solvability. Don't paper over; surface.
    throw new Error(
      `[full_step fullStep] applyPlay returned null for a play findPlay just produced. `
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
