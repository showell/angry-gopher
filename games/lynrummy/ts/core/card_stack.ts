// card_stack.ts — canonical card-stack types + classifier + verb-agnostic
// helpers + partial-ok rule + descriptive phrases.
//
// Owns the 7-kind alphabet (run, rb, set + their pair forms + singleton),
// the ClassifiedCardStack record, the rigorous `classifyStack` entry
// point, and all card-stack helpers that don't depend on a specific
// verb (peel / splice / absorb / etc.). The bfs verb library + probe
// surface sits on top of this base.

import { type Card, isRedSuit, cardLabel } from "./card.ts";

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
  // Card value cycle wraps: K → A → 2 → ... → K. K-A-2 IS a legal
  // run in Lyn Rummy.
  return v === 13 ? 1 : v + 1;
}

// --- Kind / family bookkeeping ---------------------------------------------

/** Family lookup keyed by full kind. Singleton has no family — handled
 *  inline as a special case. Mirrors python's `_FAMILY_OF_KIND`. */
export function familyOfKind(kind: Kind): Kind | null {
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
export function pairOf(family: Kind): Kind {
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
export function familyForTwoCards(c1: Card, c2: Card): Kind | null {
  const v1 = c1.rank, s1 = c1.suit;
  const v2 = c2.rank, s2 = c2.suit;
  if (v1 === v2) {
    if (s1 === s2) return null;
    return KIND_SET;
  }
  if (successor(v1) !== v2) return null;
  if (s1 === s2) return KIND_RUN;
  if (isRedSuit(s1) !== isRedSuit(s2)) return KIND_RB;
  return null;
}

// --- Kind-from-length math -------------------------------------------------

/** Kind tag for a slice of a run/rb-family stack with n cards remaining.
 *  Mirrors python's `_run_kind_for_length`. */
export function runKindForLength(family: Kind, n: number): Kind {
  if (n >= 3) return family;
  if (n === 2) return pairOf(family);
  if (n === 1) return KIND_SINGLETON;
  throw new Error("zero-length run slice is not a valid stack");
}

/** Kind tag for a remainder of a set with n cards. Mirrors python's
 *  `_set_kind_for_length`. */
export function setKindForLength(n: number): Kind {
  if (n >= 3) return KIND_SET;
  if (n === 2) return KIND_PAIR_SET;
  if (n === 1) return KIND_SINGLETON;
  throw new Error("zero-length set slice is not a valid stack");
}

/** Kind of a contiguous n-card slice of a run/rb-family stack. Returns
 *  null when the slice is empty. Mirrors python's `_slice_kind`. */
export function sliceKind(family: Kind, n: number): Kind | null {
  if (n <= 0) return null;
  if (n === 1) return KIND_SINGLETON;
  if (n === 2) return pairOf(family);
  return family;
}

// --- Construction + adjacency ----------------------------------------------

/** Build a length-1 ClassifiedCardStack. Mirrors python's `singleton`. */
export function singletonStack(card: Card): ClassifiedCardStack {
  return { cards: [card], kind: KIND_SINGLETON, n: 1 };
}

/** Single-boundary legality check for `family`. Caller has already
 *  determined the family from the parent kinds. Mirrors python's
 *  `_boundary_ok`. */
export function boundaryOk(a: Card, b: Card, family: Kind): boolean {
  const av = a.rank, asu = a.suit;
  const bv = b.rank, bsu = b.suit;
  if (family === KIND_SET) {
    return av === bv && asu !== bsu;
  }
  if (family === KIND_RUN) {
    return asu === bsu && successor(av) === bv;
  }
  if (family === KIND_RB) {
    if (successor(av) !== bv) return false;
    return isRedSuit(asu) !== isRedSuit(bsu);
  }
  return false;
}

// --- Classifier ------------------------------------------------------------

function classifyPair(cards: readonly Card[]): Kind | null {
  const a = cards[0]!;
  const b = cards[1]!;
  const av = a.rank, asu = a.suit;
  const bv = b.rank, bsu = b.suit;
  if (av === bv) {
    return asu !== bsu ? KIND_PAIR_SET : null;
  }
  if (successor(av) !== bv) return null;
  if (asu === bsu) return KIND_PAIR_RUN;
  if (isRedSuit(asu) !== isRedSuit(bsu)) return KIND_PAIR_RB;
  return null;
}

function classifyLong(cards: readonly Card[]): Kind | null {
  const a0 = cards[0]!;
  const a1 = cards[1]!;
  const a0v = a0.rank, a0s = a0.suit;
  const a1v = a1.rank, a1s = a1.suit;
  const n = cards.length;

  // SET path: same value, distinct suits.
  if (a0v === a1v) {
    if (a0s === a1s) return null;
    const seen = new Set<number>([a0s, a1s]);
    for (let i = 2; i < n; i++) {
      const c = cards[i]!;
      const cv = c.rank, cs = c.suit;
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
      if (c.rank !== successor(prevV) || c.suit !== a0s) return null;
      prevV = c.rank;
    }
    return KIND_RUN;
  }

  // Rb run: alternating colors with successive values.
  const a0red = isRedSuit(a0s);
  const a1red = isRedSuit(a1s);
  if (a0red === a1red) return null;
  let prevV = a1v;
  let prevRed = a1red;
  for (let i = 2; i < n; i++) {
    const c = cards[i]!;
    if (c.rank !== successor(prevV)) return null;
    const cRed = isRedSuit(c.suit);
    if (cRed === prevRed) return null;
    prevV = c.rank;
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

// --- Higher-level predicates -----------------------------------------------

/** True iff `stack` is a length-3+ legal group (run / rb / set). */
export function isCompleteGroup(stack: readonly Card[]): boolean {
  const k = classifyStack(stack)?.kind;
  return k === KIND_RUN || k === KIND_RB || k === KIND_SET;
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
  if (successor(a.rank) === b.rank) {
    if (a.suit === b.suit) return true;            // pure-run partial
    if (isRedSuit(a.suit) !== isRedSuit(b.suit)) return true;  // rb-run partial
  }
  // Set partial: same value, different suit.
  if (a.rank === b.rank && a.suit !== b.suit) return true;
  return false;
}

// --- Descriptive phrases ---------------------------------------------------
//
// English fragments describing a stack's shape. Used by the BFS Move
// renderers (narrate / hint) and any other UI that needs a one-liner
// for a card-stack shape.

export function groupKindPhrase(stack: readonly Card[]): string {
  const k = classifyStack(stack)?.kind;
  if (k === KIND_SET) return "a set";
  if (k === KIND_RUN) return "a pure run";
  if (k === KIND_RB) return "a red-black run";
  return "a partial";
}

export function partialKindPhrase(stack: readonly Card[]): string {
  const n = stack.length;
  if (n === 0) return "an empty target";
  if (n === 1) return `the ${cardLabel(stack[0]!)}`;
  return "the partial [" + stack.map(cardLabel).join(" ") + "]";
}

export function runKindPhrase(stack: readonly Card[]): string {
  const k = classifyStack(stack)?.kind;
  if (k === KIND_RUN) return "pure run";
  if (k === KIND_RB) return "red-black run";
  return "run";
}
