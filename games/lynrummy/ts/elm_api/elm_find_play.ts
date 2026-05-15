// elm_find_play.ts — Elm puzzles UI entry. Board+hand DSL in,
// primitives DSL out (or empty string = no play). DSL vocabulary
// lives in dsl/parse.ts + dsl/emit.ts.

import type { BoardStack } from "../geometry/geometry.ts";
import { applyLocally } from "../game_events/primitives.ts";
import { findPlayPrimitives } from "../plan/play.ts";
import { parseBoardDsl, parseCardList } from "../dsl/parse.ts";
import { formatPrimitive } from "../dsl/emit.ts";

export function elmFindPlay(boardDsl: string, handDsl: string): string {
  const board = parseBoardDsl(boardDsl);
  const hand = parseCardList(handDsl.replace(/#.*$/, ""));
  const result = findPlayPrimitives(board, hand);
  if (result === null) return "";
  const lines: string[] = [];
  let sim: readonly BoardStack[] = board;
  for (const p of result.step.prims) {
    lines.push(formatPrimitive(p, sim));
    sim = applyLocally(sim, p);
  }
  return lines.join("\n");
}
