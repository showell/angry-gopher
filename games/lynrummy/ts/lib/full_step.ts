// full_step.ts — one step of an agent's turn. Main entry:
// `fullStep(board, hand)`. Decides what the agent does next:
// groom-when-available, otherwise play-when-available, otherwise end.
// This is the load-bearing boundary for an agent move — the same
// surface a human watching agent-as-Player-Two will dispatch
// against, call by call.
//
// The three step kinds:
//   - GroomStep  (see groom.ts) — board cleanup
//   - PlayStep   (see play.ts)  — one findPlay → applyPlay round-trip
//   - EndStep    — no groom AND no play possible; turn over
//
// FullStep = the two progress kinds (groom or play). EndStep is the
// "no progress" terminator and is not itself a step in the turn's
// stream.

import type { Card } from "../src/rules/card.ts";
import { tryGroom } from "./groom.ts";
import { tryPlay } from "./play.ts";
import { assertBoardClean } from "./board.ts";
import type { GroomStep, PlayStep, EndStep } from "./step_types.ts";

/** One step result, plus the post-step (board, hand). For `end` the
 *  state is unchanged from the inputs; for `groom`/`play` the state
 *  reflects what would be on the board if the step's effects were
 *  applied. */
export interface FullStepResult {
  readonly step: GroomStep | PlayStep | EndStep;
  readonly board: readonly (readonly Card[])[];
  readonly hand: readonly Card[];
}

/** The agent's per-step contract. Each call returns one of:
 *
 *    - `groom` — a non-empty batch of run-merges to animate
 *    - `play`  — one findPlay→applyPlay round-trip with placements
 *    - `end`   — no groom available AND no play available; turn over
 *
 *  Empty grooms are never returned — if `tryGroom` finds nothing,
 *  we silently fall through to `tryPlay`. EndStep's `outcome`
 *  distinguishes "hand empty" from "stuck with cards in hand." */
export function fullStep(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
): FullStepResult {
  const tStart = performance.now();

  const groomed = tryGroom(board);
  if (groomed !== null) {
    assertBoardClean(groomed.board, "fullStep after-groom");
    return { step: groomed.step, board: groomed.board, hand };
  }

  const played = tryPlay(board, hand, tStart);
  if (played !== null) {
    return played;
  }

  const outcome = hand.length === 0 ? "hand_empty" : "stuck";
  return { step: { kind: "end", outcome }, board, hand };
}
