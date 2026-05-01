// classified_card_stack.ts — TS port of python/classified_card_stack.py.
//
// First milestone: classify_stack only. The full module (verbs, absorb
// probes, extends_tables, splice probes) ports leaf-by-leaf as the DSL
// conformance suite drives them in.
//
// The 7-kind alphabet matches Python exactly. No KIND_OTHER — invalid
// input returns null from classify_stack; the caller boundary
// (classify_buckets, eventually) raises on invalid stacks.

import type { Card } from "./rules/card.ts";
import { RED } from "./rules/card.ts";

export const KIND_RUN = "run";
export const KIND_RB = "rb";
export const KIND_SET = "set";
export const KIND_PAIR_RUN = "pair_run";
export const KIND_PAIR_RB = "pair_rb";
export const KIND_PAIR_SET = "pair_set";
export const KIND_SINGLETON = "singleton";

/** Discriminated union over the 7-kind alphabet. */
export type Kind =
  | typeof KIND_RUN
  | typeof KIND_RB
  | typeof KIND_SET
  | typeof KIND_PAIR_RUN
  | typeof KIND_PAIR_RB
  | typeof KIND_PAIR_SET
  | typeof KIND_SINGLETON;

/**
 * Immutable card stack + cached kind + cached length. Mirrors
 * Python's `ClassifiedCardStack` dataclass shape — three named
 * fields, no methods. Construction goes through `classifyStack`
 * (or, later, the verb / absorb / splice executors).
 */
export interface ClassifiedCardStack {
  readonly cards: readonly Card[];
  readonly kind: Kind;
  readonly n: number;
}

function successor(v: number): number {
  return v === 13 ? 1 : v + 1;
}

function classifyPair(cards: readonly Card[]): Kind | null {
  const a = cards[0]!;
  const b = cards[1]!;
  const av = a[0], asu = a[1];
  const bv = b[0], bsu = b[1];
  if (av === bv) {
    return asu !== bsu ? KIND_PAIR_SET : null;
  }
  if (successor(av) !== bv) return null;
  if (asu === bsu) return KIND_PAIR_RUN;
  if (RED.has(asu) !== RED.has(bsu)) return KIND_PAIR_RB;
  return null;
}

function classifyLong(cards: readonly Card[]): Kind | null {
  const a0 = cards[0]!;
  const a1 = cards[1]!;
  const a0v = a0[0], a0s = a0[1];
  const a1v = a1[0], a1s = a1[1];
  const n = cards.length;

  // SET path: same value, distinct suits.
  if (a0v === a1v) {
    if (a0s === a1s) return null;
    const seen = new Set<number>([a0s, a1s]);
    for (let i = 2; i < n; i++) {
      const c = cards[i]!;
      const cv = c[0], cs = c[1];
      if (cv !== a0v || seen.has(cs)) return null;
      seen.add(cs);
    }
    return KIND_SET;
  }

  // Run/rb path: successive values.
  if (successor(a0v) !== a1v) return null;

  // Pure run: same suit throughout.
  if (a0s === a1s) {
    let prevV = a1v;
    for (let i = 2; i < n; i++) {
      const c = cards[i]!;
      if (c[0] !== successor(prevV) || c[1] !== a0s) return null;
      prevV = c[0];
    }
    return KIND_RUN;
  }

  // Rb run: alternating colors with successive values.
  const a0red = RED.has(a0s);
  const a1red = RED.has(a1s);
  if (a0red === a1red) return null;
  let prevV = a1v;
  let prevRed = a1red;
  for (let i = 2; i < n; i++) {
    const c = cards[i]!;
    if (c[0] !== successor(prevV)) return null;
    const cRed = RED.has(c[1]);
    if (cRed === prevRed) return null;
    prevV = c[0];
    prevRed = cRed;
  }
  return KIND_RB;
}

function classifyRaw(cards: readonly Card[]): Kind | null {
  const n = cards.length;
  if (n === 0) return null;
  if (n === 1) return KIND_SINGLETON;
  if (n === 2) return classifyPair(cards);
  return classifyLong(cards);
}

/**
 * Run the rigorous classifier. Returns a CCS on success, null on
 * invalid input. Use this at the input boundary; afterwards every
 * stack is already classified.
 */
export function classifyStack(cards: readonly Card[]): ClassifiedCardStack | null {
  const kind = classifyRaw(cards);
  if (kind === null) return null;
  return { cards, kind, n: cards.length };
}
