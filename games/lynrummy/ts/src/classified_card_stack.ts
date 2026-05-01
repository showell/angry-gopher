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

// --- Absorb probes ---------------------------------------------------------
//
// Per SOLVER.md's no-side-parameter discipline these are TWO SEPARATE
// FUNCTIONS, not one with a `side` parameter. Each does its own job.

/** Family lookup keyed by full kind. Singleton has no family — handled
 *  inline as a special case. Mirrors python's `_FAMILY_OF_KIND`. */
function familyOfKind(kind: Kind): Kind | null {
  switch (kind) {
    case KIND_RUN:
    case KIND_PAIR_RUN:
      return KIND_RUN;
    case KIND_RB:
    case KIND_PAIR_RB:
      return KIND_RB;
    case KIND_SET:
    case KIND_PAIR_SET:
      return KIND_SET;
    default:
      return null;
  }
}

/** Length-3+ family kind → its pair-form kind. Mirrors python's `_PAIR_OF`. */
function pairOf(family: Kind): Kind {
  switch (family) {
    case KIND_RUN:
      return KIND_PAIR_RUN;
    case KIND_RB:
      return KIND_PAIR_RB;
    case KIND_SET:
      return KIND_PAIR_SET;
    default:
      throw new Error(`pairOf: unexpected family ${family}`);
  }
}

/** Family two cards form when adjacent in (c1, c2) order, or null if no
 *  legal pair. Mirrors python's `_family_for_two_cards`. Order matters
 *  for run/rb (successor is directional); set is symmetric on value. */
function familyForTwoCards(c1: Card, c2: Card): Kind | null {
  const v1 = c1[0], s1 = c1[1];
  const v2 = c2[0], s2 = c2[1];
  if (v1 === v2) {
    if (s1 === s2) return null;
    return KIND_SET;
  }
  if (successor(v1) !== v2) return null;
  if (s1 === s2) return KIND_RUN;
  if (RED.has(s1) !== RED.has(s2)) return KIND_RB;
  return null;
}

/**
 * Probe: what kind would (target.cards + [card]) classify as, or null
 * if illegal. Mirrors python's `kind_after_absorb_right`.
 */
export function kindAfterAbsorbRight(
  target: ClassifiedCardStack,
  card: Card,
): Kind | null {
  const targetKind = target.kind;
  const nNew = target.n + 1;

  if (targetKind === KIND_SINGLETON) {
    const only = target.cards[0]!;
    const family = familyForTwoCards(only, card); // boundary order: only, card
    if (family === null) return null;
    return pairOf(family);
  }

  const family = familyOfKind(targetKind)!;
  const last = target.cards[target.cards.length - 1]!;
  const av = last[0], asu = last[1];
  const bv = card[0], bsu = card[1];

  if (family === KIND_RUN) {
    if (asu !== bsu || (av === 13 ? 1 : av + 1) !== bv) return null;
  } else if (family === KIND_RB) {
    if ((av === 13 ? 1 : av + 1) !== bv) return null;
    if (RED.has(asu) === RED.has(bsu)) return null;
  } else {
    // KIND_SET
    if (av !== bv || asu === bsu) return null;
    if (nNew > 4) return null;
    for (const c of target.cards) {
      if (c[1] === bsu) return null;
    }
  }

  if (nNew >= 3) return family;
  return pairOf(family);
}

// --- Extenders (earned-knowledge structure on absorbers) -------------------
//
// `extendsTables(target)` returns three Maps in canonical reading
// order: (left, right, set). Each maps a SHAPE id (encoded as
// `value * 4 + suit`) to the result kind that absorbing a card of
// that shape would produce. The three Maps are mutually disjoint —
// a shape lives in at most one of them. Mirrors python's
// `extends_tables`. See SOLVER.md § Three-bucket extends.

/** Encode a (value, suit) pair as a single primitive key. value ∈ [1,13],
 *  suit ∈ [0,3]; the product is unique, dense, and comparable in O(1). */
export type ExtenderShape = number;

export function shapeId(value: number, suit: number): ExtenderShape {
  return value * 4 + suit;
}

/** Decode a shape id back into (value, suit). Used for diagnostics
 *  and the conformance runner. */
export function shapeFrom(id: ExtenderShape): readonly [number, number] {
  return [Math.floor(id / 4), id % 4] as const;
}

export type ExtenderMap = Map<ExtenderShape, Kind>;
export type ExtendersTriple = readonly [ExtenderMap, ExtenderMap, ExtenderMap];

function extendsForSingleton(only: Card): ExtendersTriple {
  const v = only[0];
  const s = only[1];
  const succV = v === 13 ? 1 : v + 1;
  const predV = v === 1 ? 13 : v - 1;
  const onlyRed = RED.has(s);

  const left: ExtenderMap = new Map();
  const right: ExtenderMap = new Map();
  // Pair_run: same suit at pred (left) / succ (right).
  left.set(shapeId(predV, s), KIND_PAIR_RUN);
  right.set(shapeId(succV, s), KIND_PAIR_RUN);
  // Pair_rb: opp-color suits at pred (left) / succ (right).
  for (let ss = 0; ss < 4; ss++) {
    if (RED.has(ss) !== onlyRed) {
      left.set(shapeId(predV, ss), KIND_PAIR_RB);
      right.set(shapeId(succV, ss), KIND_PAIR_RB);
    }
  }
  // Pair_set: same value, different suit. Symmetric → set bucket.
  const setMap: ExtenderMap = new Map();
  for (let ss = 0; ss < 4; ss++) {
    if (ss !== s) setMap.set(shapeId(v, ss), KIND_PAIR_SET);
  }
  return [left, right, setMap];
}

/**
 * Earned shape tables for an absorber target. Returns three maps in
 * (left, right, set) reading order. Built once per absorber at the
 * commitment point; the BFS hot path consumes them via lookups.
 *
 * Mirrors python's `extends_tables`.
 */
export function extendsTables(target: ClassifiedCardStack): ExtendersTriple {
  const cards = target.cards;
  const kind = target.kind;
  const n = target.n;

  if (kind === KIND_SINGLETON) {
    return extendsForSingleton(cards[0]!);
  }

  const family = familyOfKind(kind)!;
  const nNew = n + 1;
  const resultKind: Kind = nNew >= 3 ? family : pairOf(family);

  if (family === KIND_RUN) {
    const last = cards[cards.length - 1]!;
    const first = cards[0]!;
    const succV = last[0] === 13 ? 1 : last[0] + 1;
    const predV = first[0] === 1 ? 13 : first[0] - 1;
    const left: ExtenderMap = new Map([[shapeId(predV, first[1]), resultKind]]);
    const right: ExtenderMap = new Map([[shapeId(succV, last[1]), resultKind]]);
    return [left, right, new Map()];
  }

  if (family === KIND_RB) {
    const last = cards[cards.length - 1]!;
    const first = cards[0]!;
    const succV = last[0] === 13 ? 1 : last[0] + 1;
    const predV = first[0] === 1 ? 13 : first[0] - 1;
    const lastRed = RED.has(last[1]);
    const firstRed = RED.has(first[1]);
    const left: ExtenderMap = new Map();
    const right: ExtenderMap = new Map();
    for (let s = 0; s < 4; s++) {
      if (RED.has(s) !== firstRed) left.set(shapeId(predV, s), resultKind);
      if (RED.has(s) !== lastRed) right.set(shapeId(succV, s), resultKind);
    }
    return [left, right, new Map()];
  }

  // KIND_SET / KIND_PAIR_SET — sets are unordered.
  if (nNew > 4) {
    return [new Map(), new Map(), new Map()];
  }
  const setValue = cards[0]![0];
  const usedSuits = new Set<number>();
  for (const c of cards) usedSuits.add(c[1]);
  const setMap: ExtenderMap = new Map();
  for (let s = 0; s < 4; s++) {
    if (!usedSuits.has(s)) setMap.set(shapeId(setValue, s), resultKind);
  }
  return [new Map(), new Map(), setMap];
}

/**
 * Probe: what kind would ([card] + target.cards) classify as, or null
 * if illegal. Mirrors python's `kind_after_absorb_left`.
 */
export function kindAfterAbsorbLeft(
  target: ClassifiedCardStack,
  card: Card,
): Kind | null {
  const targetKind = target.kind;
  const nNew = target.n + 1;

  if (targetKind === KIND_SINGLETON) {
    const only = target.cards[0]!;
    const family = familyForTwoCards(card, only); // boundary order: card, only
    if (family === null) return null;
    return pairOf(family);
  }

  const family = familyOfKind(targetKind)!;
  const av = card[0], asu = card[1];
  const first = target.cards[0]!;
  const bv = first[0], bsu = first[1];

  if (family === KIND_RUN) {
    if (asu !== bsu || (av === 13 ? 1 : av + 1) !== bv) return null;
  } else if (family === KIND_RB) {
    if ((av === 13 ? 1 : av + 1) !== bv) return null;
    if (RED.has(asu) === RED.has(bsu)) return null;
  } else {
    // KIND_SET
    if (av !== bv || asu === bsu) return null;
    if (nNew > 4) return null;
    // Card's suit is `asu` (card sits on the left of target).
    for (const c of target.cards) {
      if (c[1] === asu) return null;
    }
  }

  if (nNew >= 3) return family;
  return pairOf(family);
}
