// buckets.ts — 4-bucket BFS state shape + state_sig + boundary helper.
//
// TS port of python/buckets.py. Mirrors the Python NamedTuple/Buckets
// shape with plain readonly objects. Bucket entries inside the BFS are
// always ClassifiedCardStack — `classifyBuckets` is the boundary that
// converts a raw `Buckets` of card-list stacks into a CCS-shaped one.
// Inside BFS the "no KIND_OTHER" invariant holds by construction.

import type { Card } from "./rules/card.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "./classified_card_stack.ts";

/** Bucket name for absorbers (TROUBLE or GROWING). */
export type BucketName = "trouble" | "growing";

/** A 4-bucket state. Inside BFS each Stack is a ClassifiedCardStack;
 *  at the boundary it's a raw `readonly Card[]`. The two shapes share
 *  this record because boundary code constructs RawBuckets and BFS
 *  code immediately classifies them via `classifyBuckets`. */
export interface Buckets {
  readonly helper: readonly ClassifiedCardStack[];
  readonly trouble: readonly ClassifiedCardStack[];
  readonly growing: readonly ClassifiedCardStack[];
  readonly complete: readonly ClassifiedCardStack[];
}

/** Raw input shape: each bucket holds card-list stacks. The boundary
 *  helper `classifyBuckets` consumes this and produces a `Buckets`. */
export interface RawBuckets {
  readonly helper: readonly (readonly Card[])[];
  readonly trouble: readonly (readonly Card[])[];
  readonly growing: readonly (readonly Card[])[];
  readonly complete: readonly (readonly Card[])[];
}

/** Lineage = focus queue. lineage[0] is the focus (a tuple of raw
 *  cards). Content-based identity for memoization. */
export type Lineage = readonly (readonly Card[])[];

/** BFS state with attached focus queue. Mirrors python's FocusedState.
 *  `uncommittedPairs` is the set of pair-keys (sorted, joined card
 *  encodings) for pairs that were SPAWNED from helper extracts —
 *  i.e., pairs that aren't real commitments and may legally be
 *  decomposed. Pairs formed by absorb-onto-partial are commitments
 *  and not in this set. */
export interface FocusedState {
  readonly buckets: Buckets;
  readonly lineage: Lineage;
  readonly uncommittedPairs?: ReadonlySet<string>;
}

/** Build a canonical pair-key from two cards (order-insensitive). */
export function pairKey(a: Card, b: Card): string {
  const ka = ((a[0] * 4) + a[1]) * 2 + a[2];
  const kb = ((b[0] * 4) + b[1]) * 2 + b[2];
  return ka < kb ? `${ka},${kb}` : `${kb},${ka}`;
}

// --- State signature -------------------------------------------------------
//
// DESIGN DECISION (state_sig hashing strategy):
//
// Python uses tuples-of-tuples-of-cards as `seen` set keys, relying on
// Python's deep tuple equality. JS Set/Map uses reference equality, so
// tuple-of-tuples doesn't work as a key. We need a stable, deterministic
// string encoding.
//
// Encoding chosen: pack each card into a single integer (12 bits is
// plenty: value*4*2 + suit*2 + deck → max = 13*8 + 3*2 + 1 = 111), join
// cards within a stack with `,`, sort stacks lexicographically within
// each bucket, join bucket strings with `;`, and join buckets with `|`.
// Lineage joins separately with `~` and the whole thing concatenates.
//
// Why packed-int strings:
//   - Far cheaper than JSON.stringify (no quotes, escapes, or recursion).
//   - Maintains determinism: same buckets always hash to same string.
//   - Lexicographic sort on packed-int strings is canonical because we
//     pad cards to 3 chars so card 0=A,Cl,d0 sorts before 100=…
//   - Order-insensitive within a stack (we sort) and within a bucket
//     (we sort). Order BETWEEN buckets is preserved: HELPER vs COMPLETE
//     are different roles, so bucket order matters.
//
// Tradeoff: a few extra string allocations per state expansion vs.
// JSON.stringify, but avoids the JSON parser overhead and stays in
// strict ASCII. Hot-path-acceptable.
//
// Lineage is folded INTO the state-sig: in Python, the seen-set key is
// (state_sig, lineage). Encoding both into one string saves the per-key
// tuple allocation in JS (where small object keys are not hash-friendly).

const CARD_PAD = 4; // packed cards are <= 4 ASCII digits → "0"-"9999"

function encodeCard(c: Card): string {
  // value ∈ [1,13], suit ∈ [0,3], deck ∈ [0,1]
  // packed = ((value*4) + suit) * 2 + deck → max = 111. Pad to 4 digits
  // for stable lexicographic ordering when joining sorted stacks.
  const id = ((c[0] * 4) + c[1]) * 2 + c[2];
  return id.toString().padStart(CARD_PAD, "0");
}

/** Encode a stack's cards (already sorted). */
function encodeStackCards(cards: readonly Card[]): string {
  // Stable per-stack ordering: sort by packed id. Within-stack order
  // doesn't affect identity (the BFS treats stacks as multisets here
  // because two stacks with the same cards represent the same state
  // even if iteration order differs).
  const ids = cards.map(encodeCard);
  ids.sort();
  return ids.join(",");
}

/** Encode a bucket of CCS stacks: sort the per-stack strings and join
 *  with ';'. Within-bucket order doesn't matter; cross-stack identity
 *  is content-based. */
function encodeBucket(stacks: readonly ClassifiedCardStack[]): string {
  const stackStrs = stacks.map(s => encodeStackCards(s.cards));
  stackStrs.sort();
  return stackStrs.join(";");
}

/** Encode a lineage (tuple of raw card tuples). Lineage POSITION
 *  matters (lineage[0] is focus), so we DON'T sort the outer list.
 *  Lineage entries are encoded VERBATIM (no per-entry sort) — Python's
 *  seen-set key uses the raw lineage tuple, so same-cards-different-
 *  order entries are distinct states there and must be distinct here.
 *  In practice all lineage entries land in canonical order by
 *  construction (descriptors emit cards sorted), so this is invisible
 *  today; verbatim encoding pins port fidelity if that invariant ever
 *  breaks. */
function encodeLineage(lineage: Lineage): string {
  return lineage.map(entry => entry.map(encodeCard).join(",")).join("~");
}

/**
 * Compute the canonical state signature (memoization key). Bucket order
 * matters (HELPER vs COMPLETE differ in role) but stack order within a
 * bucket doesn't. Result is a string suitable as a `Set` / `Map` key.
 *
 * `lineage` defaults to no lineage; pass it in to fold lineage identity
 * into the same key (matching python's `(state_sig(*b), lineage)`).
 */
/** Build a position-of-cardId map from a full game's initial state.
 *  Iterates all buckets, collects card-ids in encounter order, and
 *  returns the inverse: posOf[cardId] = position 0..N-1.
 *  Use ONCE per game; pass to fastStateSig on every call. */
export function buildCardOrder(initial: Buckets): {
  cardOrder: readonly number[];
  posOf: Uint8Array;
} {
  const cardId = (c: Card): number => (c[0] - 1) * 8 + c[1] * 2 + c[2];
  const cardOrder: number[] = [];
  const seen = new Set<number>();
  const collect = (stacks: readonly ClassifiedCardStack[]): void => {
    for (const stack of stacks) for (const c of stack.cards) {
      const id = cardId(c);
      if (!seen.has(id)) { seen.add(id); cardOrder.push(id); }
    }
  };
  collect(initial.helper);
  collect(initial.trouble);
  collect(initial.growing);
  collect(initial.complete);
  // posOf indexed by 0..103 (full card-id space); 255 for not-in-game.
  const posOf = new Uint8Array(104);
  posOf.fill(255);
  for (let i = 0; i < cardOrder.length; i++) {
    posOf[cardOrder[i]!] = i;
  }
  return { cardOrder, posOf };
}

/** Fast state-sig: per-position byte-array encoding. The buffer has
 *  length = N (cards-in-play, typically 50-80) — much smaller than the
 *  full 208-byte fixed array. Each byte encodes:
 *    Top 2 bits: bucket_id (0=helper, 1=trouble, 2=growing, 3=complete)
 *    Bottom 7 bits: right-neighbor position (0..N-1) or 127 = end-of-stack
 *  (N ≤ 104 so 7 bits suffice; bucket fits in 2.)
 *
 *  Two states with the same per-position (bucket, right_neighbor) ARE
 *  the same set of stacks per bucket — no need to sort.
 *  Lineage head positions appended after a 0xFF separator. */
export function fastStateSig(
  b: Buckets,
  lineage: Lineage | undefined,
  posOf: Uint8Array,
  N: number,
): string {
  const buf = new Uint8Array(N);
  // Default 0 doesn't naturally distinguish "not present" — but every
  // card has a position so EVERY byte gets written by writeBucket.
  // (If a card moved to COMPLETE it's still "in the game" and gets
  // bucket=3.)
  const cardId = (c: Card): number => (c[0] - 1) * 8 + c[1] * 2 + c[2];
  const writeBucket = (
    stacks: readonly ClassifiedCardStack[],
    bucketId: number,
  ): void => {
    for (const stack of stacks) {
      // Canonicalize within-stack order: sort card positions ascending.
      const positions: number[] = [];
      for (const c of stack.cards) positions.push(posOf[cardId(c)]!);
      positions.sort((a, b) => a - b);
      for (let i = 0; i < positions.length; i++) {
        const pos = positions[i]!;
        const right = i + 1 < positions.length ? positions[i + 1]! : 127;
        buf[pos] = (bucketId << 7) | right;  // 1 bit bucket | 7 bits right
        // (bucketId is 0..3, but we only have 1 free bit after 7-bit
        // right-neighbor. Use 2 bytes per card if we need 4 buckets.)
      }
    }
  };
  // 4 buckets need 2 bits, but we squeezed only 1 here. Use 2 bytes/card:
  const buf2 = new Uint8Array(2 * N);
  const writeBucket2 = (
    stacks: readonly ClassifiedCardStack[],
    bucketId: number,
  ): void => {
    for (const stack of stacks) {
      const positions: number[] = [];
      for (const c of stack.cards) positions.push(posOf[cardId(c)]!);
      positions.sort((a, b) => a - b);
      for (let i = 0; i < positions.length; i++) {
        const pos = positions[i]!;
        buf2[2 * pos] = bucketId;
        buf2[2 * pos + 1] = i + 1 < positions.length ? positions[i + 1]! : 255;
      }
    }
  };
  writeBucket2(b.helper, 0);
  writeBucket2(b.trouble, 1);
  writeBucket2(b.growing, 2);
  writeBucket2(b.complete, 3);

  let result = String.fromCharCode.apply(null, buf2 as unknown as number[]);

  if (lineage !== undefined && lineage.length > 0) {
    const lbuf = new Uint8Array(lineage.length);
    for (let i = 0; i < lineage.length; i++) {
      lbuf[i] = posOf[cardId(lineage[i]![0]!)]!;
    }
    result += "@" + String.fromCharCode.apply(null, lbuf as unknown as number[]);
  }
  return result;
  void buf; void writeBucket;  // silence unused
}

export function stateSig(
  b: Buckets,
  lineage?: Lineage,
  uncommittedPairs?: ReadonlySet<string>,
): string {
  const h = encodeBucket(b.helper);
  const t = encodeBucket(b.trouble);
  const g = encodeBucket(b.growing);
  const c = encodeBucket(b.complete);
  const base = `${h}|${t}|${g}|${c}`;
  let withLineage = base;
  if (lineage !== undefined) withLineage = `${base}@${encodeLineage(lineage)}`;
  if (uncommittedPairs === undefined || uncommittedPairs.size === 0) return withLineage;
  const sortedKeys = [...uncommittedPairs].sort();
  return `${withLineage}#${sortedKeys.join(",")}`;
}

// --- Bucket-level operations ----------------------------------------------

export function troubleCount(
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
): number {
  let n = 0;
  for (const s of trouble) n += s.n;
  for (const s of growing) n += s.n;
  return n;
}

export function isVictory(
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
): boolean {
  if (trouble.length > 0) return false;
  for (const g of growing) {
    if (g.n < 3) return false;
  }
  return true;
}

// --- Boundary conversion --------------------------------------------------

function classifyBucket(
  stacks: readonly (readonly Card[])[],
  bucketName: string,
): ClassifiedCardStack[] {
  const out: ClassifiedCardStack[] = [];
  for (let i = 0; i < stacks.length; i++) {
    const ccs = classifyStack(stacks[i]!);
    if (ccs === null) {
      throw new Error(
        `invalid stack in ${bucketName}[${i}]: ${JSON.stringify(stacks[i])} `
        + "did not classify as run/rb/set/pair_*/singleton",
      );
    }
    out.push(ccs);
  }
  return out;
}

/**
 * Convert a raw `RawBuckets` (lists of lists of cards) into a `Buckets`
 * of CCS. Throws on any stack that fails to classify — those are caller
 * bugs, not BFS bugs.
 *
 * Mirrors python's `classify_buckets`. Use this at every BFS boundary.
 */
export function classifyBuckets(buckets: RawBuckets): Buckets {
  return {
    helper: classifyBucket(buckets.helper, "helper"),
    trouble: classifyBucket(buckets.trouble, "trouble"),
    growing: classifyBucket(buckets.growing, "growing"),
    complete: classifyBucket(buckets.complete, "complete"),
  };
}
