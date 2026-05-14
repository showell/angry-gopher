import type { Card } from "../core/card.ts";
import type { Primitive } from "../game_events/primitives.ts";

export interface GroomStep {
  readonly kind: "groom";
  readonly prims: readonly Primitive[];
}

export interface PlayStep {
  readonly kind: "play";
  readonly cardsToPlay: readonly Card[];
  readonly prims: readonly Primitive[];
}

export interface EndStep {
  readonly kind: "end";
  readonly outcome: "hand_empty" | "stuck";
}

// EndStep deliberately omitted — it terminates a turn, not composes one.
export type TurnStep = GroomStep | PlayStep;
