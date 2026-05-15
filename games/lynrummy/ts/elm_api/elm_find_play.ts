// elm_find_play.ts — Elm puzzles UI entry: take board+hand as DSL,
// return the play's primitive sequence as DSL.
//
// DSL is the lingua franca: the wrapper parses board + hand DSL on
// the way in, runs the canonical TS planner (findPlayPrimitives),
// and renders the resulting primitives as line-per-primitive DSL on
// the way out. Conformance tests treat the DSL as the assertion
// surface — no parse-back required.
//
// Inbound DSL shapes:
//   board  — newline-separated `at (top, left): card1 card2 ...` lines
//   hand   — single line of space-separated card labels (may be empty)
//
// Outbound DSL — newline-separated, one primitive per line:
//   place_hand <card> -> (top,left)
//   merge_hand <card> -> [<stack cards>] /<side>
//   merge_stack [<src cards>] -> [<tgt cards>] /<side>
//   split [<stack cards>]@<index>
//   move_stack [<stack cards>] -> (top,left)
//
// Empty string return = no play possible (mirrors findPlayPrimitives
// returning null).

import { type Card, cardLabel, parseCardList } from "../core/card.ts";
import { type BoardStack, parseBoardStackLine } from "../geometry/geometry.ts";
import { type Primitive, applyLocally } from "../game_events/primitives.ts";
import { findPlayPrimitives } from "../plan/play.ts";

export function elmFindPlay(boardDsl: string, handDsl: string): string {
  const board = parseBoardDsl(boardDsl);
  const hand = parseCardList(stripComments(handDsl));
  const result = findPlayPrimitives(board, hand);
  if (result === null) return "";
  return renderPrimitives(board, result.step.prims);
}

// --- DSL parsers ----------------------------------------------------
//
// Both leaf parsers (parseBoardStackLine, parseCardList) come from
// core/geometry — same parsers conformance_dsl.ts uses.

function parseBoardDsl(dsl: string): BoardStack[] {
  const out: BoardStack[] = [];
  for (const raw of dsl.split("\n")) {
    const line = stripComments(raw);
    if (line === "") continue;
    out.push(parseBoardStackLine(line));
  }
  return out;
}

function stripComments(s: string): string {
  return s.replace(/#.*$/, "").trim();
}

// --- DSL emitter ----------------------------------------------------

function renderPrimitives(
  initialBoard: readonly BoardStack[],
  prims: readonly Primitive[],
): string {
  const lines: string[] = [];
  let sim: readonly BoardStack[] = initialBoard;
  for (const p of prims) {
    lines.push(formatPrimitive(p, sim));
    sim = applyLocally(sim, p);
  }
  return lines.join("\n");
}

function formatPrimitive(p: Primitive, board: readonly BoardStack[]): string {
  switch (p.action) {
    case "split":
      return `split [${fmtCards(board[p.stackIndex]!.cards)}]@${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack [${fmtCards(board[p.sourceStack]!.cards)}] -> [${fmtCards(board[p.targetStack]!.cards)}] /${p.side}`;
    case "merge_hand":
      return `merge_hand ${cardLabel(p.handCard)} -> [${fmtCards(board[p.targetStack]!.cards)}] /${p.side}`;
    case "move_stack":
      return `move_stack [${fmtCards(board[p.stackIndex]!.cards)}] -> (${p.newLoc.top},${p.newLoc.left})`;
    case "place_hand":
      return `place_hand ${cardLabel(p.handCard)} -> (${p.loc.top},${p.loc.left})`;
  }
}

function fmtCards(cs: readonly Card[]): string {
  return cs.map(cardLabel).join(" ");
}
