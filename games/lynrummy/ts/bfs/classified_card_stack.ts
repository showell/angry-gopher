// classified_card_stack.ts — verb library + probe surface on top of the
// canonical card-stack base in `../core/card_stack.ts`.
//
// Owns the absorb probes (kindAfterAbsorbLeft/Right), the earned-shape
// extends tables, the verb predicates + executors (peel/setPeel/pluck/
// yank/steal/splitOut), and the splice probes + candidate enumerator.
// All verb-agnostic helpers (kind/family bookkeeping, kind-from-length
// math, singleton construction, boundary check, classifyStack) live in
// `core/card_stack.ts`.

import { type Card, isRedSuit } from "../core/card.ts";
import {
  type Kind,
  type ClassifiedCardStack,
  KIND_RUN,
  KIND_RB,
  KIND_SET,
  KIND_PAIR_RUN,
  KIND_PAIR_RB,
  KIND_PAIR_SET,
  KIND_SINGLETON,
  classifyStack,
  classifyPair,
  familyOfKind,
  pairOf,
  singletonStack,
  sliceKind,
  kindForLength,
  boundaryOk,
  successor,
  predecessor,
} from "../core/card_stack.ts";

// --- Absorb probes ---------------------------------------------------------
//
// Per SOLVER.md's no-side-parameter discipline these are TWO SEPARATE
// FUNCTIONS, not one with a `side` parameter. Each does its own job.

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
    return classifyPair([only, card]); // boundary order: only, card
  }

  const family = familyOfKind(targetKind)!;
  const last = target.cards[target.cards.length - 1]!;
  const av = last.rank, asu = last.suit;
  const bv = card.rank, bsu = card.suit;

  if (family === KIND_RUN) {
    if (asu !== bsu || successor(av) !== bv) return null;
  } else if (family === KIND_RB) {
    if (successor(av) !== bv) return null;
    if (isRedSuit(asu) === isRedSuit(bsu)) return null;
  } else {
    // KIND_SET
    if (av !== bv || asu === bsu) return null;
    if (nNew > 4) return null;
    for (const c of target.cards) {
      if (c.suit === bsu) return null;
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
// a shape lives in at most one of them. See ENGINE_V2.md §
// Three-bucket extends for the design rationale.

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
  const v = only.rank;
  const s = only.suit;
  const succV = successor(v);
  const predV = predecessor(v);
  const onlyRed = isRedSuit(s);

  const left: ExtenderMap = new Map();
  const right: ExtenderMap = new Map();
  // Pair_run: same suit at pred (left) / succ (right).
  left.set(shapeId(predV, s), KIND_PAIR_RUN);
  right.set(shapeId(succV, s), KIND_PAIR_RUN);
  // Pair_rb: opp-color suits at pred (left) / succ (right).
  for (let ss = 0; ss < 4; ss++) {
    if (isRedSuit(ss) !== onlyRed) {
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
    const succV = successor(last.rank);
    const predV = predecessor(first.rank);
    const left: ExtenderMap = new Map([[shapeId(predV, first.suit), resultKind]]);
    const right: ExtenderMap = new Map([[shapeId(succV, last.suit), resultKind]]);
    return [left, right, new Map()];
  }

  if (family === KIND_RB) {
    const last = cards[cards.length - 1]!;
    const first = cards[0]!;
    const succV = successor(last.rank);
    const predV = predecessor(first.rank);
    const lastRed = isRedSuit(last.suit);
    const firstRed = isRedSuit(first.suit);
    const left: ExtenderMap = new Map();
    const right: ExtenderMap = new Map();
    for (let s = 0; s < 4; s++) {
      if (isRedSuit(s) !== firstRed) left.set(shapeId(predV, s), resultKind);
      if (isRedSuit(s) !== lastRed) right.set(shapeId(succV, s), resultKind);
    }
    return [left, right, new Map()];
  }

  // KIND_SET / KIND_PAIR_SET — sets are unordered.
  if (nNew > 4) {
    return [new Map(), new Map(), new Map()];
  }
  const setValue = cards[0]!.rank;
  const usedSuits = new Set<number>();
  for (const c of cards) usedSuits.add(c.suit);
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
    return classifyPair([card, only]); // boundary order: card, only
  }

  const family = familyOfKind(targetKind)!;
  const av = card.rank, asu = card.suit;
  const first = target.cards[0]!;
  const bv = first.rank, bsu = first.suit;

  if (family === KIND_RUN) {
    if (asu !== bsu || successor(av) !== bv) return null;
  } else if (family === KIND_RB) {
    if (successor(av) !== bv) return null;
    if (isRedSuit(asu) === isRedSuit(bsu)) return null;
  } else {
    // KIND_SET
    if (av !== bv || asu === bsu) return null;
    if (nNew > 4) return null;
    // Card's suit is `asu` (card sits on the left of target).
    for (const c of target.cards) {
      if (c.suit === asu) return null;
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

/** Set-peel: drop one card from a length-3 SET, leaving the other
 *  two as a coherent pair_set. Companion to `steal` (which atomizes
 *  the SET into two singletons); both verbs are enumerated for every
 *  position so A* sees both post-state options. Distinguished from
 *  `peel` (length-4+ source) so the enumerator can tell them apart
 *  in plan-line text and in the spawn-bucket routing. Per Steve,
 *  2026-05-04: avoiding silly split-then-rejoin sequences. */
export function canSetPeel(stack: ClassifiedCardStack, i: number): boolean {
  return stack.kind === KIND_SET && stack.n === 3 && i >= 0 && i < 3;
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

/** Steal: extract a card from a short stack.
 *
 *  Length-3 sources: end positions for run/rb; any position for set.
 *  Length-2 sources (pair_run/pair_rb/pair_set): either position —
 *  the residual is a singleton, which is always a legal kind.
 *
 *  Length-2 stealing matches the human "AS is a resource" intuition
 *  from a kitchen-table game: cards trapped in a partial are still
 *  donor-eligible; pulling one out leaves the other as a singleton. */
export function canSteal(stack: ClassifiedCardStack, i: number): boolean {
  if (stack.n === 3) {
    if (stack.kind === KIND_RUN || stack.kind === KIND_RB) {
      return i === 0 || i === 2;
    }
    return stack.kind === KIND_SET;
  }
  if (stack.n === 2) {
    return stack.kind === KIND_PAIR_RUN
      || stack.kind === KIND_PAIR_RB
      || stack.kind === KIND_PAIR_SET;
  }
  return false;
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
    return [extracted, { cards: rest, kind: kindForLength(KIND_SET, rest.length), n: rest.length }];
  }
  const family = stack.kind;
  const rest: Card[] =
    i === 0 ? stack.cards.slice(1) : stack.cards.slice(0, -1);
  return [extracted, { cards: rest, kind: kindForLength(family, rest.length), n: rest.length }];
}

/**
 * Set-peel executor. Assumes `canSetPeel(stack, i)`. Returns
 * `[extracted, pair_set_remnant]` — the remnant is a coherent
 * length-2 pair_set that stays together (in contrast to `steal`,
 * which atomizes the source SET into singletons). Caller routes
 * the pair_set into GROWING.
 */
export function setPeel(
  stack: ClassifiedCardStack,
  i: number,
): readonly ClassifiedCardStack[] {
  if (!canSetPeel(stack, i)) {
    throw new Error(`canSetPeel(${stack.kind} len=${stack.n}, ${i}) is False`);
  }
  const extracted = singletonStack(stack.cards[i]!);
  const rest: Card[] = stack.cards.slice(0, i).concat(stack.cards.slice(i + 1));
  return [extracted, { cards: rest, kind: KIND_PAIR_SET, n: 2 }];
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
    { cards: leftCards, kind: kindForLength(family, leftCards.length), n: leftCards.length },
    { cards: rightCards, kind: kindForLength(family, rightCards.length), n: rightCards.length },
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
  // Length-2 source: residual is the other card as a singleton.
  if (stack.n === 2) {
    const otherIdx = i === 0 ? 1 : 0;
    return [extracted, singletonStack(stack.cards[otherIdx]!)];
  }
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
    const ccs = classifyStack([parentCards[0]!, card]);
    if (ccs === null) return null;
    leftKind = ccs.kind;
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
    const ccs = classifyStack([card, parentCards[position]!]);
    if (ccs === null) return null;
    rightKind = ccs.kind;
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
  const cv = card.rank;
  const cs = card.suit;
  const family = parent.kind;
  const cRed = isRedSuit(cs);
  const out: SpliceCandidate[] = [];
  for (let m = 2; m <= n - 3; m++) {
    const pm = cards[m]!;
    if (pm.rank !== cv) continue;
    if (family === KIND_RB) {
      // Card must match parent[m]'s color (rb alternation continuation).
      if (isRedSuit(pm.suit) !== cRed) continue;
    } else {
      // KIND_RUN: card must match parent[m]'s suit (pure-run invariant).
      if (pm.suit !== cs) continue;
    }
    out.push({ side: "left", position: m, leftKind: family, rightKind: family });
    out.push({ side: "right", position: m + 1, leftKind: family, rightKind: family });
  }
  return out;
}
