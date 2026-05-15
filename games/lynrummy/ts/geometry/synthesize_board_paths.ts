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

import type { Card } from "../core/card.ts";
import { CARD_PITCH, type BoardStack } from "./geometry.ts";


const DRAG_MS_PER_PIXEL = 2.5;
const SAMPLES = 20;


export interface TimeLoc { tMs: number; left: number; top: number }

/** A non-empty sample list. The animator (Elm) requires at
 *  least one point — encoded in the type so a path-less merge/
 *  move can't be constructed by accident. SAMPLES is 20, so
 *  every synthesized path is comfortably non-empty in practice.
 */
export type BoardPath = readonly [TimeLoc, ...readonly TimeLoc[]];

interface Point { x: number; y: number }


/** Synthesize the path Elm's replay would have JIT-built for
 *  a move_stack action. `source.loc` → `newLoc`. */
export function moveStackPath(source: BoardStack, newLoc: { left: number; top: number }): BoardPath {
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
  source: BoardStack,
  target: BoardStack,
  side: "left" | "right",
): BoardPath {
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
 *  uses for JIT path synthesis. Returns a non-empty path
 *  (SAMPLES = 20, so always 20 points). */
function easedPath(start: Point, end: Point): BoardPath {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  const dist = Math.sqrt(dx * dx + dy * dy);
  const duration = Math.max(100, dist * DRAG_MS_PER_PIXEL);

  const sample = (i: number): TimeLoc => {
    const frac = i / (SAMPLES - 1);
    const pos = quinticEase(frac);
    return {
      tMs: Math.round(frac * duration),
      left: Math.round(start.x + dx * pos),
      top: Math.round(start.y + dy * pos),
    };
  };

  const first = sample(0);
  const rest: TimeLoc[] = [];
  for (let i = 1; i < SAMPLES; i++) {
    rest.push(sample(i));
  }
  return [first, ...rest];
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
