// stack_type.ts — Stack-level rule predicates.
//
// TS port of python/rules/stack_type.py. The full Python module also
// holds the `classify` function; here we delegate to
// `classifyStack` from `../classified_card_stack.ts` for that path.
// This file holds the predicates that don't need a CCS — they sit
// closer to the rules layer.

import type { Card } from "./card.ts";
import { isRedSuit } from "./card.ts";
import { classifyStack } from "../classified_card_stack.ts";

function successor(v: number): number {
  // Card value cycle wraps: K → A → 2 → ... → K. K-A-2 IS a legal
  // run in Lyn Rummy. Mirrors python `rules.stack_type.successor`.
  return v === 13 ? 1 : v + 1;
}

/**
 * True iff `stack` is a legal group OR a length-2 partial that could
 * grow into one. Mirrors python `rules.stack_type.is_partial_ok`.
 *
 * Used to validate intermediate extends — a beginner is allowed to
 * pair up two cards into a transient they'll finish on the next move.
 *
 * Length 0 / 1 always pass. Length >= 3 must classify as a complete
 * group (run / rb_run / set). Length 2 passes if it could grow into
 * any of the three group types.
 */
export function isPartialOk(stack: readonly Card[]): boolean {
  const n = stack.length;
  if (n === 0) return true;
  if (n === 1) return true;
  if (n >= 3) return classifyStack(stack) !== null;
  // n === 2
  const a = stack[0]!;
  const b = stack[1]!;
  // Run partial: successor + same suit (pure) or different color (rb).
  if (successor(a[0]) === b[0]) {
    if (a[1] === b[1]) return true;            // pure-run partial
    if (isRedSuit(a[1]) !== isRedSuit(b[1])) return true;  // rb-run partial
  }
  // Set partial: same value, different suit.
  if (a[0] === b[0] && a[1] !== b[1]) return true;
  return false;
}
