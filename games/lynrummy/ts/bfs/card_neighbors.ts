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
//   cardId(c) = (rank - 1) * 8 + suit * 2 + deck
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
// extracts them. Correctness-safe over-approximation — false-positive
// liveness, never false-negative.

import { type Card, Rank, Suit, Deck, isRedSuit } from "../core/card.ts";
import type { Buckets } from "./buckets.ts";
import type { ClassifiedCardStack } from "../core/card_stack.ts";

// --- Card encoding ----------------------------------------------------

function cardId(c: Card): number {
  return (c.rank - 1) * 8 + c.suit * 2 + c.deck;
}

// --- Bucket tags ------------------------------------------------------

const ABSENT = 0;
const HELPER = 1;
const TROUBLE = 2;
const GROWING = 3;
const COMPLETE = 4;

// --- Neighbor-table construction --------------------------------------

function suitsInColor(red: boolean): Suit[] {
  const out: Suit[] = [];
  for (const s of [Suit.Club, Suit.Diamond, Suit.Spade, Suit.Heart]) {
    if (isRedSuit(s) === red) out.push(s);
  }
  return out;
}

function combinations3<T>(arr: readonly T[]): [T, T, T][] {
  const out: [T, T, T][] = [];
  for (let i = 0; i < arr.length; i++)
    for (let j = i + 1; j < arr.length; j++)
      for (let k = j + 1; k < arr.length; k++)
        out.push([arr[i]!, arr[j]!, arr[k]!]);
  return out;
}

function buildNeighbors(): readonly (readonly (readonly [number, number])[])[] {
  const out: [number, number][][] = [];
  for (let i = 0; i < 104; i++) out.push([]);

  function addTriple(c1: Card, c2: Card, c3: Card): void {
    const i1 = cardId(c1), i2 = cardId(c2), i3 = cardId(c3);
    out[i1]!.push([i2, i3]);
    out[i2]!.push([i1, i3]);
    out[i3]!.push([i1, i2]);
  }

  const allSuits: Suit[] = [Suit.Club, Suit.Diamond, Suit.Spade, Suit.Heart];
  const allDecks: Deck[] = [Deck.One, Deck.Two];

  // Sets: same rank, three distinct suits, decks chosen independently.
  for (let v = 1 as Rank; v <= 13; v++) {
    for (const [s1, s2, s3] of combinations3(allSuits)) {
      for (const d1 of allDecks)
        for (const d2 of allDecks)
          for (const d3 of allDecks)
            addTriple(
              { rank: v, suit: s1, deck: d1 },
              { rank: v, suit: s2, deck: d2 },
              { rank: v, suit: s3, deck: d3 },
            );
    }
  }

  // Pure runs: same suit, three consecutive ranks (K wraps to A).
  for (let v0 = 1 as Rank; v0 <= 13; v0++) {
    const v1 = ((v0 % 13) + 1) as Rank;
    const v2 = ((v1 % 13) + 1) as Rank;
    for (const s of allSuits) {
      for (const d0 of allDecks)
        for (const d1 of allDecks)
          for (const d2 of allDecks)
            addTriple(
              { rank: v0, suit: s, deck: d0 },
              { rank: v1, suit: s, deck: d1 },
              { rank: v2, suit: s, deck: d2 },
            );
    }
  }

  // RB runs: alternating colors, three consecutive ranks. Both
  // start_red parities (RBR + BRB).
  for (let v0 = 1 as Rank; v0 <= 13; v0++) {
    const v1 = ((v0 % 13) + 1) as Rank;
    const v2 = ((v1 % 13) + 1) as Rank;
    for (const startRed of [true, false]) {
      const suits0 = suitsInColor(startRed);
      const suits1 = suitsInColor(!startRed);
      const suits2 = suits0;
      for (const s0 of suits0)
        for (const s1 of suits1)
          for (const s2 of suits2)
            for (const d0 of allDecks)
              for (const d1 of allDecks)
                for (const d2 of allDecks)
                  addTriple(
                    { rank: v0, suit: s0, deck: d0 },
                    { rank: v1, suit: s1, deck: d1 },
                    { rank: v2, suit: s2, deck: d2 },
                  );
    }
  }

  return out;
}

const NEIGHBORS: readonly (readonly (readonly [number, number])[])[]
  = buildNeighbors();

// --- Card-location array + liveness query -----------------------------

/** From a Buckets state, return a 104-element Uint8Array mapping
 *  cardId → bucket tag. Cards not on the board are ABSENT (0).
 *  Buckets must be CCS-shaped. */
function buildCardLoc(b: Buckets): Uint8Array {
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
 *  sealed and don't count. */
function isLive(c: Card, cardLoc: Uint8Array): boolean {
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

/** Pre-flight: false if any trouble singleton has no accessible
 *  partner pair anywhere on the board. Such a state is provably
 *  unwinnable. */
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
