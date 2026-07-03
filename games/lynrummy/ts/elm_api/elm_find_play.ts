// elm_find_play.ts — the full-game agent-step entry (the real-time
// opponent). Board+hand DSL in, primitives DSL out (or empty string =
// no play). Reached via engine_entry.ts:elmAgentStep ← the `agent_step`
// glue op, which only Game.elm sends; puzzles don't use it. DSL
// vocabulary lives in dsl/parse.ts + dsl/emit.ts.

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
