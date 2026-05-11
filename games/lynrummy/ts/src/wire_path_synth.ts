// wire_path_synth.ts — synthesize a realistic board-drag path
// for an agent-emitted action. Port of Elm's
// Game.Replay.Space.{easedPath, boardEndpoints} (deleted with
// the rest of /Replay in commit c85567a, backed up in
// /tmp/Replay-backup-20260509-150005/Space.elm), which itself
// was a port of Python's gesture_synth.
//
// Quintic smootherstep on 20 samples, duration = max(100,
// distance * 2.5) ms. Endpoints follow the live wire shape:
//   move_stack: source.loc → newLoc
//   merge_stack: source.loc → target.loc with the side offset
//                (+/- targetSize * CARD_PITCH for right/left)
//                plus the +2/-2 jitter the wing-snap tolerance
//                forgives.
//
// Path tMs values start at 0 (the agent has no global clock).
// Live replay uses absolute tMs deltas, so this is fine — the
// duration is what drives animation pacing.

import type { Card } from "./rules/card.ts";
import { CARD_PITCH } from "./geometry.ts";
import type { TimeLoc, Stack } from "./wire_action_dsl.ts";


const DRAG_MS_PER_PIXEL = 2.5;
const SAMPLES = 20;


export interface Point { x: number; y: number }


/** Synthesize the path Elm's replay would have JIT-built for
 *  a move_stack action. `source.loc` → `newLoc`. */
export function moveStackPath(source: Stack, newLoc: { left: number; top: number }): TimeLoc[] {
  return easedPath(
    { x: source.loc.left, y: source.loc.top },
    { x: newLoc.left, y: newLoc.top },
  );
}


/** Synthesize the path Elm's replay would have JIT-built for
 *  a merge_stack action. End point lands `targetSize *
 *  CARD_PITCH` past the target on the chosen side, with the
 *  same +2/-2 jitter the Elm boardEndpoints uses (lands inside
 *  the wing-snap tolerance). */
export function mergeStackPath(
  source: Stack,
  target: Stack,
  side: "left" | "right",
): TimeLoc[] {
  const srcSize = source.cards.length;
  const tgtSize = target.cards.length;
  const endLeft =
    side === "right"
      ? target.loc.left + tgtSize * CARD_PITCH
      : target.loc.left - srcSize * CARD_PITCH;
  return easedPath(
    { x: source.loc.left, y: source.loc.top },
    { x: endLeft + 2, y: target.loc.top - 2 },
  );
}


/** Quintic smootherstep over 20 samples. Same algorithm Elm
 *  uses for JIT path synthesis. */
export function easedPath(start: Point, end: Point): TimeLoc[] {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  const dist = Math.sqrt(dx * dx + dy * dy);
  const duration = Math.max(100, dist * DRAG_MS_PER_PIXEL);

  const out: TimeLoc[] = [];
  for (let i = 0; i < SAMPLES; i++) {
    const frac = i / (SAMPLES - 1);
    const pos = quinticEase(frac);
    out.push({
      tMs: Math.round(frac * duration),
      left: Math.round(start.x + dx * pos),
      top: Math.round(start.y + dy * pos),
    });
  }
  return out;
}


/** Smootherstep (5th-degree polynomial). C2 continuous at the
 *  endpoints — natural-feeling start and stop. Same form
 *  Python's gesture_synth uses. */
function quinticEase(f: number): number {
  return f * f * f * (f * (f * 6 - 15) + 10);
}


// Re-export Card so the agent has one stop-shop for path types
// even when it isn't using them directly today.
export type { Card };
