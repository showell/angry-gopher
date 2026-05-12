import type { Card } from "../src/rules/card.ts";
import type { Desc } from "../src/move.ts";

// Merged stack reads `[...src, ...tgt]`, matching `merge_stack` side=left.
export interface JoinEvent {
  readonly src: readonly Card[];
  readonly tgt: readonly Card[];
}

export interface GroomStep {
  readonly kind: "groom";
  readonly joins: readonly JoinEvent[];
}

export interface PlayStep {
  readonly kind: "play";
  readonly placements: readonly Card[];
  readonly planDescs: readonly Desc[];
}

export interface EndStep {
  readonly kind: "end";
  readonly outcome: "hand_empty" | "stuck";
}

// EndStep deliberately omitted — it terminates a turn, not composes one.
export type TurnStep = GroomStep | PlayStep;
