// step_types.ts — type definitions for the three kinds of step the
// agent can take, plus the JoinEvent record used inside GroomStep.
// Pure type module: no runtime code, no algorithms. Each step kind's
// behavior lives in its own module (groom.ts for the groom path;
// PlayStep's construction lives in full_step.ts).

import type { Card } from "../src/rules/card.ts";
import type { Desc } from "../src/move.ts";

/** One greedy run-merge: the contents of the two stacks at the
 *  moment of the merge. The merged stack reads `[...src, ...tgt]`
 *  (matches `merge_stack` with side="left"). Transcript writers
 *  materialize these into wire-level `merge_stack` primitives. */
export interface JoinEvent {
  readonly src: readonly Card[];
  readonly tgt: readonly Card[];
}

/** A non-empty batch of greedy run-merges. */
export interface GroomStep {
  readonly kind: "groom";
  readonly joins: readonly JoinEvent[];
  /** Total wall time the agent spent producing this step. */
  readonly wallMs: number;
}

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

/** The step kinds that compose a turn's stream. EndStep is the
 *  terminator and is not itself a TurnStep. */
export type TurnStep = GroomStep | PlayStep;
