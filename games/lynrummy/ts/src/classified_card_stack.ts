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

// --- Source-side verbs -----------------------------------------------------
//
// The five extraction verbs: peel, pluck, yank, steal, split_out. Each
// pair is a `canX(stack, i)` predicate plus a custom `x(stack, i)`
// executor. Predicates are mutually exclusive at any (stack, i) — they
// partition the legal extraction positions into one verb each.
//
// Executors assume their precondition holds; we throw on caller bug,
// matching the no-silent-fallbacks doctrine. Remnant kinds derive from
// the parent's kind family + remnant length via the helpers below — no
// re-classification.

/** Build a length-1 ClassifiedCardStack. Mirrors python's `singleton`. */
function singletonStack(card: Card): ClassifiedCardStack {
  return { cards: [card], kind: KIND_SINGLETON, n: 1 };
}

/** Kind tag for a slice of a run/rb-family stack with n cards remaining.
 *  Mirrors python's `_run_kind_for_length`. */
function runKindForLength(family: Kind, n: number): Kind {
  if (n >= 3) return family;
  if (n === 2) return pairOf(family);
  if (n === 1) return KIND_SINGLETON;
  throw new Error("zero-length run slice is not a valid stack");
}

/** Kind tag for a remainder of a set with n cards. Mirrors python's
 *  `_set_kind_for_length`. */
function setKindForLength(n: number): Kind {
  if (n >= 3) return KIND_SET;
  if (n === 2) return KIND_PAIR_SET;
  if (n === 1) return KIND_SINGLETON;
  throw new Error("zero-length set slice is not a valid stack");
}

/** Peel: drop an end card from a length-4+ run/rb, or any card from a
 *  length-4+ set (sets are unordered). */
export function canPeel(stack: ClassifiedCardStack, i: number): boolean {
  const n = stack.n;
  if (stack.kind === KIND_SET && n >= 4) return true;
  if ((stack.kind === KIND_RUN || stack.kind === KIND_RB) && n >= 4
      && (i === 0 || i === n - 1)) {
    return true;
  }
  return false;
}

/** Pluck: drop an interior card of a run/rb such that BOTH halves remain
 *  length-3+ runs of the same family. Requires n >= 7 with i in [3, n-4]. */
export function canPluck(stack: ClassifiedCardStack, i: number): boolean {
  if (stack.kind !== KIND_RUN && stack.kind !== KIND_RB) return false;
  return 3 <= i && i <= stack.n - 4;
}

/** Yank: drop a card from a run/rb where one half is length-3+ and the
 *  other is length 1 or 2 (non-empty). Covers positions outside peel
 *  (ends) and pluck (deep interior). */
export function canYank(stack: ClassifiedCardStack, i: number): boolean {
  if (stack.kind !== KIND_RUN && stack.kind !== KIND_RB) return false;
  const n = stack.n;
  if (i === 0 || i === n - 1 || (3 <= i && i <= n - 4)) return false;
  const leftLen = i;
  const rightLen = n - i - 1;
  return Math.max(leftLen, rightLen) >= 3 && Math.min(leftLen, rightLen) >= 1;
}

/** Steal: only on length-3 stacks. End positions for run/rb; any
 *  position for set. */
export function canSteal(stack: ClassifiedCardStack, i: number): boolean {
  if (stack.n !== 3) return false;
  if (stack.kind === KIND_RUN || stack.kind === KIND_RB) {
    return i === 0 || i === 2;
  }
  return stack.kind === KIND_SET;
}

/** Split-out: extract the middle card of a length-3 run/rb. Both halves
 *  are singletons. */
export function canSplitOut(stack: ClassifiedCardStack, i: number): boolean {
  return (stack.kind === KIND_RUN || stack.kind === KIND_RB)
      && stack.n === 3 && i === 1;
}

/**
 * Peel executor. Assumes `canPeel(stack, i)`. Returns
 * `[extracted_singleton, remnant]`.
 *
 * For set: remnant is the other (n-1) cards (any value of i).
 * For run/rb at end position: remnant is the contiguous (n-1) cards on
 * the opposite side. Family preserved; length-driven kind.
 */
export function peel(
  stack: ClassifiedCardStack,
  i: number,
): readonly ClassifiedCardStack[] {
  if (!canPeel(stack, i)) {
    throw new Error(`canPeel(${stack.kind} len=${stack.n}, ${i}) is False`);
  }
  const extracted = singletonStack(stack.cards[i]!);
  if (stack.kind === KIND_SET) {
    const rest: Card[] = stack.cards.slice(0, i).concat(stack.cards.slice(i + 1));
    return [extracted, { cards: rest, kind: setKindForLength(rest.length), n: rest.length }];
  }
  const family = stack.kind;
  const rest: Card[] =
    i === 0 ? stack.cards.slice(1) : stack.cards.slice(0, -1);
  return [extracted, { cards: rest, kind: runKindForLength(family, rest.length), n: rest.length }];
}

/**
 * Pluck executor. Assumes `canPluck(stack, i)`. Returns
 * `[extracted, left, right]`. Both halves are length-3+ runs of the
 * parent family.
 */
export function pluck(
  stack: ClassifiedCardStack,
  i: number,
): readonly ClassifiedCardStack[] {
  if (!canPluck(stack, i)) {
    throw new Error(`canPluck(${stack.kind} len=${stack.n}, ${i}) is False`);
  }
  const family = stack.kind;
  const extracted = singletonStack(stack.cards[i]!);
  const leftCards: Card[] = stack.cards.slice(0, i);
  const rightCards: Card[] = stack.cards.slice(i + 1);
  return [
    extracted,
    { cards: leftCards, kind: family, n: leftCards.length },
    { cards: rightCards, kind: family, n: rightCards.length },
  ];
}

/**
 * Yank executor. Assumes `canYank(stack, i)`. Returns
 * `[extracted, left, right]`. One half is length-3+ run-family, the
 * other is length-1 (singleton) or length-2 (pair_X). Both non-empty
 * by yank precondition.
 */
export function yank(
  stack: ClassifiedCardStack,
  i: number,
): readonly ClassifiedCardStack[] {
  if (!canYank(stack, i)) {
    throw new Error(`canYank(${stack.kind} len=${stack.n}, ${i}) is False`);
  }
  const family = stack.kind;
  const extracted = singletonStack(stack.cards[i]!);
  const leftCards: Card[] = stack.cards.slice(0, i);
  const rightCards: Card[] = stack.cards.slice(i + 1);
  return [
    extracted,
    { cards: leftCards, kind: runKindForLength(family, leftCards.length), n: leftCards.length },
    { cards: rightCards, kind: runKindForLength(family, rightCards.length), n: rightCards.length },
  ];
}

/**
 * Steal executor. Assumes `canSteal(stack, i)`. Returns 2 or 3 pieces.
 *
 * For set (n=3): atomizes — returns `[extracted, *other_two_singletons]`
 * (3 pieces). BFS rule: stealing from a set destroys the set and the
 * remaining cards become independent trouble singletons rather than
 * persisting as one pair_set.
 *
 * For run/rb (n=3, i=0 or i=2): returns `[extracted, length-2 partial]`
 * (2 pieces).
 */
export function steal(
  stack: ClassifiedCardStack,
  i: number,
): readonly ClassifiedCardStack[] {
  if (!canSteal(stack, i)) {
    throw new Error(`canSteal(${stack.kind} len=${stack.n}, ${i}) is False`);
  }
  const extracted = singletonStack(stack.cards[i]!);
  if (stack.kind === KIND_SET) {
    const others: ClassifiedCardStack[] = [];
    for (let j = 0; j < stack.cards.length; j++) {
      if (j !== i) others.push(singletonStack(stack.cards[j]!));
    }
    return [extracted, ...others];
  }
  const family = stack.kind;
  const rest: Card[] =
    i === 0 ? stack.cards.slice(1) : stack.cards.slice(0, -1);
  return [extracted, { cards: rest, kind: pairOf(family), n: rest.length }];
}

/**
 * Split-out executor. Assumes `canSplitOut(stack, i)`. Length-3 run or
 * rb, i=1. Returns `[extracted, left_singleton, right_singleton]`.
 */
export function splitOut(
  stack: ClassifiedCardStack,
  i: number,
): readonly ClassifiedCardStack[] {
  if (!canSplitOut(stack, i)) {
    throw new Error(`canSplitOut(${stack.kind} len=${stack.n}, ${i}) is False`);
  }
  return [
    singletonStack(stack.cards[1]!),
    singletonStack(stack.cards[0]!),
    singletonStack(stack.cards[2]!),
  ];
}

// --- Splice probes ---------------------------------------------------------
//
// Per SOLVER.md's no-side-parameter discipline these are TWO SEPARATE
// FUNCTIONS named kindsAfterSpliceLeft and kindsAfterSpliceRight, NOT one
// function with a `side` parameter. Each does its own job.

/** Kind of a contiguous n-card slice of a run/rb-family stack. Returns
 *  null when the slice is empty. Mirrors python's `_slice_kind`. */
function sliceKind(family: Kind, n: number): Kind | null {
  if (n <= 0) return null;
  if (n === 1) return KIND_SINGLETON;
  if (n === 2) return pairOf(family);
  return family;
}

/** Single-boundary legality check for `family`. Caller has already
 *  determined the family from the parent kinds. Mirrors python's
 *  `_boundary_ok`. */
function boundaryOk(a: Card, b: Card, family: Kind): boolean {
  const av = a[0], asu = a[1];
  const bv = b[0], bsu = b[1];
  if (family === KIND_SET) {
    return av === bv && asu !== bsu;
  }
  if (family === KIND_RUN) {
    return asu === bsu && successor(av) === bv;
  }
  if (family === KIND_RB) {
    if (successor(av) !== bv) return false;
    return RED.has(asu) !== RED.has(bsu);
  }
  return false;
}

/** LEFT splice halves: with-card half first, pure slice second. Mirrors
 *  python's `_splice_halves_left`. */
function spliceHalvesLeft(
  stack: ClassifiedCardStack,
  card: Card,
  position: number,
): [Card[], Card[]] {
  const left: Card[] = stack.cards.slice(0, position).concat([card]);
  const right: Card[] = stack.cards.slice(position);
  return [left, right];
}

/** RIGHT splice halves: pure slice first, with-card half second. Mirrors
 *  python's `_splice_halves_right`. */
function spliceHalvesRight(
  stack: ClassifiedCardStack,
  card: Card,
  position: number,
): [Card[], Card[]] {
  const left: Card[] = stack.cards.slice(0, position);
  const right: Card[] = [card, ...stack.cards.slice(position)];
  return [left, right];
}

/** Run/rb-specialized LEFT splice probe. Mirrors python's
 *  `_kinds_after_splice_run_left`. */
function kindsAfterSpliceRunLeft(
  parentCards: readonly Card[],
  card: Card,
  position: number,
  family: Kind,
): readonly [Kind, Kind] | null {
  const n = parentCards.length;
  const sliceLen = n - position;
  const withCardLen = position + 1;
  const rightKind = sliceKind(family, sliceLen);
  if (rightKind === null) return null;
  let leftKind: Kind;
  if (withCardLen === 1) {
    leftKind = KIND_SINGLETON;
  } else if (withCardLen === 2) {
    const k = classifyPair([parentCards[0]!, card]);
    if (k === null) return null;
    leftKind = k;
  } else {
    if (!boundaryOk(parentCards[position - 1]!, card, family)) return null;
    leftKind = family;
  }
  return [leftKind, rightKind];
}

/** Run/rb-specialized RIGHT splice probe. Mirrors python's
 *  `_kinds_after_splice_run_right`. */
function kindsAfterSpliceRunRight(
  parentCards: readonly Card[],
  card: Card,
  position: number,
  family: Kind,
): readonly [Kind, Kind] | null {
  const n = parentCards.length;
  const sliceLen = position;
  const withCardLen = n - position + 1;
  const leftKind = sliceKind(family, sliceLen);
  if (leftKind === null) return null;
  let rightKind: Kind;
  if (withCardLen === 1) {
    rightKind = KIND_SINGLETON;
  } else if (withCardLen === 2) {
    const k = classifyPair([card, parentCards[position]!]);
    if (k === null) return null;
    rightKind = k;
  } else {
    if (!boundaryOk(card, parentCards[position]!, family)) return null;
    rightKind = family;
  }
  return [leftKind, rightKind];
}

/**
 * Probe for the LEFT splice variant on a run or rb parent.
 *     left  = stack.cards[:position] + [card]    ← with-card half
 *     right = stack.cards[position:]             ← pure slice
 * Returns `[leftKind, rightKind]` if both halves classify, else null.
 *
 * Splice is a run/rb-only operation. Set parents extend via the
 * absorb operation (set_extenders bucket); there's no such thing as
 * a "set splice" in human play. Calling this probe on a non-run/rb
 * parent throws.
 */
export function kindsAfterSpliceLeft(
  stack: ClassifiedCardStack,
  card: Card,
  position: number,
): readonly [Kind, Kind] | null {
  if (stack.kind !== KIND_RUN && stack.kind !== KIND_RB) {
    throw new Error(
      `splice probe requires run or rb parent, got ${stack.kind}`,
    );
  }
  return kindsAfterSpliceRunLeft(stack.cards, card, position, stack.kind);
}

/**
 * Probe for the RIGHT splice variant on a run or rb parent.
 *     left  = stack.cards[:position]             ← pure slice
 *     right = [card] + stack.cards[position:]    ← with-card half
 * See `kindsAfterSpliceLeft` for the run/rb-only contract.
 */
export function kindsAfterSpliceRight(
  stack: ClassifiedCardStack,
  card: Card,
  position: number,
): readonly [Kind, Kind] | null {
  if (stack.kind !== KIND_RUN && stack.kind !== KIND_RB) {
    throw new Error(
      `splice probe requires run or rb parent, got ${stack.kind}`,
    );
  }
  return kindsAfterSpliceRunRight(stack.cards, card, position, stack.kind);
}

// --- Splice candidates (earned-knowledge accelerator for the BFS) ----------
//
// `findSpliceCandidates(parent, card)` enumerates every legal splice of
// `card` into `parent` that yields TWO LENGTH-3+ family-kind halves.
// This is the BFS-useful subset of splice positions; partial-pair halves
// (length-2 with-card halves like the `pair_set | rb` cases in
// splice.dsl) are excluded by design.
//
// Algorithm: same-value-match scan. A human looking for a splice asks
// "is there a position m where parent[m] has the same value as my insert
// card?" — every BFS-useful splice arises from exactly such a match.
// Proof: for left_splice@p with both halves length-3+, the with-card
// half boundary requires successor(parent[p-1].value) = card.value, i.e.
// card.value = parent[p].value. For right_splice@p, the with-card half
// boundary requires successor(card.value) = parent[p].value, i.e.
// card.value = parent[p-1].value. So every BFS-useful splice has a
// matching parent[m] with the same value as the card, and the per-match
// emission rule is:
//
//     match at m  →  left_splice@m AND right_splice@(m+1)
//
// Both candidates require m ∈ [2, n-3] (so each half has length ≥ 3).
// At length n=4, [2, 1] is empty; this is why we skip n<5 parents.
//
// Validity per family:
//   - rb parent: card same color as parent[m] (the rb alternation
//     re-establishes when card takes parent[m]'s color slot adjacent
//     to it; suit equality is allowed because boundary checks only
//     same-color, not same-suit, and the alt-color invariant of the
//     remaining halves is unaffected).
//   - run parent: card same suit as parent[m] (so the inserted card
//     preserves the pure-suit invariant on both adjacent boundaries).
//     This is the cross-deck case in practice — same (value, suit)
//     across decks is the only realistic way to hit it.
//
// Each emitted candidate is a guaranteed-valid splice; no probe call
// is needed. The kinds are known a priori from the family because both
// halves are length-3+ family-kind slices of the parent's family.

/** A BFS-useful splice candidate: left/right side, position, and the
 *  guaranteed left/right half kinds. Both halves are length-3+
 *  family-kind stacks; no reclassification needed. */
export interface SpliceCandidate {
  readonly side: "left" | "right";
  readonly position: number;
  readonly leftKind: Kind;
  readonly rightKind: Kind;
}

/**
 * Find every splice of `card` into `parent` that yields two length-3+
 * legal halves. Uses the same-value-match heuristic; each returned
 * candidate is guaranteed valid (no probe needed). Iteration order is
 * by ascending parent match position `m`, with `left@m` emitted before
 * `right@(m+1)` for each match.
 *
 * Parent must be KIND_RUN or KIND_RB (raises otherwise; mirrors the
 * splice probes' run/rb-only contract).
 */
export function findSpliceCandidates(
  parent: ClassifiedCardStack,
  card: Card,
): readonly SpliceCandidate[] {
  if (parent.kind !== KIND_RUN && parent.kind !== KIND_RB) {
    throw new Error(
      `findSpliceCandidates requires run or rb parent, got ${parent.kind}`,
    );
  }
  const n = parent.n;
  if (n < 5) return [];
  const cards = parent.cards;
  const cv = card[0];
  const cs = card[1];
  const family = parent.kind;
  const cRed = RED.has(cs);
  const out: SpliceCandidate[] = [];
  for (let m = 2; m <= n - 3; m++) {
    const pm = cards[m]!;
    if (pm[0] !== cv) continue;
    if (family === KIND_RB) {
      // Card must match parent[m]'s color (rb alternation continuation).
      if (RED.has(pm[1]) !== cRed) continue;
    } else {
      // KIND_RUN: card must match parent[m]'s suit (pure-run invariant).
      if (pm[1] !== cs) continue;
    }
    out.push({ side: "left", position: m, leftKind: family, rightKind: family });
    out.push({ side: "right", position: m + 1, leftKind: family, rightKind: family });
  }
  return out;
}
