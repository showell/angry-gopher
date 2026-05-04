// card_neighbors.ts — per-card partner-pair tables for fast singleton
// liveness queries.
//
// For each card c (encoded as 0..103), NEIGHBORS[c] is the list of
// unordered pairs (c1_id, c2_id) such that {c, c1, c2} forms a valid
// 3-card group (set / pure run / rb run). Built once at module load.
//
// Used to short-circuit BFS searches where a trouble singleton has no
// accessible partner pair anywhere in (helper ∪ trouble ∪ growing) —
// such a state is provably unwinnable.
//
// Card encoding (0..103):
//   cardId(value, suit, deck) = (value - 1) * 8 + suit * 2 + deck
//
// Bucket tags for per-state card_loc array:
//   ABSENT = 0
//   HELPER = 1
//   TROUBLE = 2
//   GROWING = 3
//   COMPLETE = 4   (sealed; doesn't count as accessible partner)
//
// GROWING is conservative on purpose: cards in a growing 2-partial
// are treated as accessible partners even though no BFS move
// extracts them (growing isn't an extract source). This is a
// correctness-safe over-approximation — false-positive liveness,
// never false-negative — so plan quality is preserved.
//
// Tried and rejected (don't re-derive these):
//
// 1. Replacing isPartialOk length-2 with a precomputed pair-partner
//    set. The 5-branch tower framing was misleading — isPartialOk is
//    an early-return chain that exits in ~3 ops for the dominant
//    case, while a hash lookup needs ~10 ops.
// 2. Hoisting cardLoc into enumerateMoves as plumbing for future
//    consumers. Building it per state without an immediate consumer
//    is pure overhead.
// 3. Pushing the dynamic doomed-singleton prune unconditionally on
//    every state. Per-state cost dominated the prune savings; gating
//    on graduation events (len(complete) > parentCompleteCount) is
//    load-bearing.

import type { Card } from "./rules/card.ts";
import { RED } from "./rules/card.ts";
import type { Buckets } from "./buckets.ts";
import type { ClassifiedCardStack } from "./classified_card_stack.ts";

// --- Card encoding ----------------------------------------------------

export function cardId(c: Card): number {
  return (c[0] - 1) * 8 + c[1] * 2 + c[2];
}

// --- Bucket tags ------------------------------------------------------

export const ABSENT = 0;
export const HELPER = 1;
export const TROUBLE = 2;
export const GROWING = 3;
export const COMPLETE = 4;

// --- Neighbor-table construction --------------------------------------

function suitsInColor(red: boolean): number[] {
  const out: number[] = [];
  for (let s = 0; s < 4; s++) if (RED.has(s) === red) out.push(s);
  return out;
}

function combinations3(arr: readonly number[]): [number, number, number][] {
  const out: [number, number, number][] = [];
  for (let i = 0; i < arr.length; i++)
    for (let j = i + 1; j < arr.length; j++)
      for (let k = j + 1; k < arr.length; k++)
        out.push([arr[i]!, arr[j]!, arr[k]!]);
  return out;
}

function buildNeighbors(): readonly (readonly [number, number])[][] {
  const out: [number, number][][] = [];
  for (let i = 0; i < 104; i++) out.push([]);

  function addTriple(c1: Card, c2: Card, c3: Card): void {
    const i1 = cardId(c1), i2 = cardId(c2), i3 = cardId(c3);
    out[i1]!.push([i2, i3]);
    out[i2]!.push([i1, i3]);
    out[i3]!.push([i1, i2]);
  }

  // Sets: same value, three distinct suits, decks chosen independently.
  for (let v = 1; v <= 13; v++) {
    for (const [s1, s2, s3] of combinations3([0, 1, 2, 3])) {
      for (let d1 = 0; d1 < 2; d1++)
        for (let d2 = 0; d2 < 2; d2++)
          for (let d3 = 0; d3 < 2; d3++)
            addTriple([v, s1, d1], [v, s2, d2], [v, s3, d3]);
    }
  }

  // Pure runs: same suit, three consecutive values (K wraps to A).
  for (let v0 = 1; v0 <= 13; v0++) {
    const v1 = (v0 % 13) + 1;
    const v2 = (v1 % 13) + 1;
    for (let s = 0; s < 4; s++) {
      for (let d0 = 0; d0 < 2; d0++)
        for (let d1 = 0; d1 < 2; d1++)
          for (let d2 = 0; d2 < 2; d2++)
            addTriple([v0, s, d0], [v1, s, d1], [v2, s, d2]);
    }
  }

  // RB runs: alternating colors, three consecutive values. Both
  // start_red parities (RBR + BRB).
  for (let v0 = 1; v0 <= 13; v0++) {
    const v1 = (v0 % 13) + 1;
    const v2 = (v1 % 13) + 1;
    for (const startRed of [true, false]) {
      const suits0 = suitsInColor(startRed);
      const suits1 = suitsInColor(!startRed);
      const suits2 = suits0;
      for (const s0 of suits0)
        for (const s1 of suits1)
          for (const s2 of suits2)
            for (let d0 = 0; d0 < 2; d0++)
              for (let d1 = 0; d1 < 2; d1++)
                for (let d2 = 0; d2 < 2; d2++)
                  addTriple([v0, s0, d0], [v1, s1, d1], [v2, s2, d2]);
    }
  }

  return out;
}

export const NEIGHBORS: readonly (readonly (readonly [number, number])[])[]
  = buildNeighbors();

// --- Card-location array + liveness query -----------------------------

/** From a Buckets state, return a 104-element Uint8Array mapping
 *  cardId → bucket tag. Cards not on the board are ABSENT (0).
 *  Buckets must be CCS-shaped. */
export function buildCardLoc(b: Buckets): Uint8Array {
  const loc = new Uint8Array(104);  // zero-init = ABSENT
  const tag = (stacks: readonly ClassifiedCardStack[], t: number): void => {
    for (const stack of stacks)
      for (const c of stack.cards) loc[cardId(c)] = t;
  };
  tag(b.helper, HELPER);
  tag(b.trouble, TROUBLE);
  tag(b.growing, GROWING);
  tag(b.complete, COMPLETE);
  return loc;
}

/** True iff `c` has at least one pair of accessible partners on the
 *  board (tag in {HELPER, TROUBLE, GROWING}). COMPLETE cards are
 *  sealed and don't count. O(|NEIGHBORS[c]|) ≈ O(72) per call. */
export function isLive(c: Card, cardLoc: Uint8Array): boolean {
  const cid = cardId(c);
  const pairs = NEIGHBORS[cid]!;
  for (const [c1, c2] of pairs) {
    const loc1 = cardLoc[c1]!;
    const loc2 = cardLoc[c2]!;
    if (loc1 > 0 && loc1 < 4 && loc2 > 0 && loc2 < 4) return true;
  }
  return false;
}

// --- Filters used by the BFS engine -----------------------------------

/** Pre-flight: false if any trouble singleton has no accessible partner
 *  pair anywhere on the board. Such a state is provably unwinnable. */
export function allTroubleSingletonsLive(b: Buckets): boolean {
  let hasSingleton = false;
  for (const t of b.trouble) if (t.n === 1) { hasSingleton = true; break; }
  if (!hasSingleton) return true;
  const cardLoc = buildCardLoc(b);
  for (const t of b.trouble) {
    if (t.n !== 1) continue;
    if (!isLive(t.cards[0]!, cardLoc)) return false;
  }
  return true;
}

/** Dynamic per-state companion. Caller must gate on "this move
 *  graduated a group" — the only way a partner can transition out of
 *  the accessible pool mid-search. Returns true if any trouble
 *  singleton is now newly dead (sealed partners). */
export function anyTroubleSingletonNewlyDoomed(b: Buckets): boolean {
  let hasSingleton = false;
  for (const t of b.trouble) if (t.n === 1) { hasSingleton = true; break; }
  if (!hasSingleton) return false;
  const cardLoc = buildCardLoc(b);
  for (const t of b.trouble) {
    if (t.n !== 1) continue;
    if (!isLive(t.cards[0]!, cardLoc)) return true;
  }
  return false;
}
