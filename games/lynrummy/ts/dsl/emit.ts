// dsl/emit.ts — canonical DSL emitters. The DSL is the lingua
// franca for everything DSL-adjacent: conformance test pins,
// fixture inputs, the live agent-step wire to Elm. There is ONE
// canonical shape — the action-log format spoken by
// `Lib.GameEvent` / `Lib.WireAction` on the Elm side:
//
//   split [<cards>] at (<l>,<t>) @<index>
//   merge_stack [<src>] at (<l>,<t>) -> [<tgt>] at (<l>,<t>) /<side> :: path (...)
//   merge_hand <card> -> [<tgt>] at (<l>,<t>) /<side>
//   move_stack [<cards>] at (<l>,<t>) -> (<l>,<t>) :: path (...)
//   place_hand <card> -> (<l>,<t>)
//
// Conventions across every emitter:
//   - Coordinates as (left, top) — left first.
//   - Card glyphs as Unicode suits (♣ ♦ ♠ ♥); deck-2 trailing `'`.
//   - Stack references always carry their `at (l,t)`.
//   - merge_stack and move_stack always carry their `:: path (...)`
//     suffix — the Elm animator requires a non-empty path; the
//     primitive type carries it as `BoardPath` (non-empty by
//     construction), so the emitter cannot drop it accidentally.
//
// Seq prefix (`N) `) and the `complete_turn` keyword are envelope
// concerns; they live here too so callers have one stop-shop for
// DSL-adjacent output.

import { type Card, cardLabel } from "../core/card.ts";
import type { BoardStack, Loc } from "../geometry/geometry.ts";
import type { Primitive } from "../game_events/primitives.ts";
import type { BoardPath } from "../geometry/synthesize_board_paths.ts";

/** One Primitive as its canonical DSL line. The `board` argument
 *  is the live stack-list at the moment of emission — callers that
 *  walk a primitive sequence must apply each primitive (via
 *  applyLocally) before formatting the next. */
export function formatPrimitive(p: Primitive, board: readonly BoardStack[]): string {
  switch (p.action) {
    case "split":
      return `split ${formatStackRef(board[p.stackIndex]!)} @${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack ${formatStackRef(board[p.sourceStack]!)} -> ${formatStackRef(board[p.targetStack]!)} /${p.side}${formatPathSuffix(p.path)}`;
    case "merge_hand":
      return `merge_hand ${cardLabel(p.handCard)} -> ${formatStackRef(board[p.targetStack]!)} /${p.side}`;
    case "move_stack":
      return `move_stack ${formatStackRef(board[p.stackIndex]!)} -> ${formatLoc(p.newLoc)}${formatPathSuffix(p.path)}`;
    case "place_hand":
      return `place_hand ${cardLabel(p.handCard)} -> ${formatLoc(p.loc)}`;
  }
}

/** Seq-number prefix used by transcripts and the action log:
 *  `<n>) `. The full action-log line is `seqPrefix(n) + body`. */
export function seqPrefix(n: number): string {
  return n + ") ";
}

/** Standalone `complete_turn` keyword (no body, no path). Used by
 *  transcripts at the end of every turn. */
export const completeTurnDsl = "complete_turn";

function formatPathSuffix(path: BoardPath): string {
  const samples = path
    .map((p) => `(${p.left},${p.top}@${p.tMs})`)
    .join("");
  return ` :: path ${samples}`;
}

/** "at (l,t): card1 card2 ..." — the canonical board-stack line
 *  used in fixture board: blocks and as the inbound shape for the
 *  Elm puzzle/agent wrappers. */
export function formatBoardStackLine(s: BoardStack): string {
  return `at ${formatLoc(s.loc)}: ${formatCardList(s.cards)}`;
}

/** "card1 card2 ..." with Unicode suit glyphs and apostrophes
 *  for deck-2. Empty input → empty string. */
export function formatCardList(cards: readonly Card[]): string {
  return cards.map(cardLabel).join(" ");
}

function formatStackRef(s: BoardStack): string {
  return `[${formatCardList(s.cards)}] at ${formatLoc(s.loc)}`;
}

function formatLoc(loc: Loc): string {
  return `(${loc.left},${loc.top})`;
}
