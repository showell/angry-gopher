// dsl/parse.ts — single home for the universal-DSL parsers used
// across production + test code. The DSL vocabulary covered here
// is what every consumer (conformance scenarios, Elm puzzles
// wrapper, test runners) speaks: cards, hands, board stacks.
//
// Returned shapes are the natural domain shapes (Card, BoardStack)
// — no fixture-shaped wrappers, no snake_case `state` fields.
// Callers that need transport-shaped objects build them by adapting
// these natural shapes; the parser is not the place for that
// translation.

import { type Card, parseCardLabel } from "../core/card.ts";
import type { BoardStack } from "../geometry/geometry.ts";

/** Whitespace-separated list of card labels: "5H 6H 7H'".
 *  Empty / whitespace-only input returns []. */
export function parseCardList(s: string): Card[] {
  if (s.trim() === "") return [];
  return s.trim().split(/\s+/).filter(Boolean).map(parseCardLabel);
}

/** One DSL board-stack line: "at (left, top): card1 card2 ...".
 *  Throws on malformed input — the message includes the offending
 *  line for debugging, but no line-number context (callers that
 *  have line numbers should add them via try/catch). */
export function parseBoardStackLine(line: string): BoardStack {
  const trimmed = line.trim();
  if (!trimmed.startsWith("at ")) {
    throw new Error(`expected "at (left,top): cards", got: ${JSON.stringify(line)}`);
  }
  const rest = trimmed.slice("at ".length);
  const close = rest.indexOf(")");
  if (!rest.startsWith("(") || close < 0) {
    throw new Error(`bad location in: ${JSON.stringify(line)}`);
  }
  const [leftStr, topStr] = rest.slice(1, close).split(",").map(s => s.trim());
  const tail = rest.slice(close + 1).trim();
  if (!tail.startsWith(":")) {
    throw new Error(`expected ":" after location in: ${JSON.stringify(line)}`);
  }
  return {
    loc: { top: parseInt(topStr!, 10), left: parseInt(leftStr!, 10) },
    cards: parseCardList(tail.slice(1).trim()),
  };
}

/** Multi-line DSL board: each non-blank, non-comment line is one
 *  "at (left, top): cards" entry. `#` to end-of-line is a comment. */
export function parseBoardDsl(dsl: string): BoardStack[] {
  const out: BoardStack[] = [];
  for (const raw of dsl.split("\n")) {
    const stripped = raw.replace(/#.*$/, "").trim();
    if (stripped === "") continue;
    out.push(parseBoardStackLine(stripped));
  }
  return out;
}
