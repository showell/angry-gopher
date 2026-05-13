import type { Card } from "../src/rules/card.ts";
import type { BoardStack } from "../src/geometry.ts";
import { tryGroom } from "./groom.ts";
import { tryPlay } from "./play.ts";
import { assertBoardClean } from "./board.ts";
import type { GroomStep, PlayStep, EndStep } from "./step_types.ts";

export interface FullStepResult {
  readonly step: GroomStep | PlayStep | EndStep;
  readonly board: readonly BoardStack[];
  readonly hand: readonly Card[];
}

export function fullStep(
  board: readonly BoardStack[],
  hand: readonly Card[],
): FullStepResult {
  const groomed = tryGroom(board);
  if (groomed !== null) {
    assertBoardClean(groomed.board, "fullStep after-groom");
    return { step: groomed.step, board: groomed.board, hand };
  }

  const played = tryPlay(board, hand);
  if (played !== null) {
    return played;
  }

  const outcome = hand.length === 0 ? "hand_empty" : "stuck";
  return { step: { kind: "end", outcome }, board, hand };
}
