import type { Card } from "../core/card.ts";
import type { Primitive } from "../game_events/primitives.ts";

export interface GroomStep {
  readonly kind: "groom";
  readonly prims: readonly Primitive[];
}

export interface PlayStep {
  readonly kind: "play";
  readonly placements: readonly Card[];
  readonly prims: readonly Primitive[];
  /** Plan-line strings, for hint display + downstream filters
   *  (puzzle catalog picks plays whose `planLines.length`
   *  matches a target). Not the primitive count. */
  readonly planLines: readonly string[];
}

export interface EndStep {
  readonly kind: "end";
  readonly outcome: "hand_empty" | "stuck";
}

// EndStep deliberately omitted — it terminates a turn, not composes one.
export type TurnStep = GroomStep | PlayStep;
