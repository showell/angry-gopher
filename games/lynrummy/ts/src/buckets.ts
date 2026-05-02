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

/** BFS state with attached focus queue. Mirrors python's FocusedState. */
export interface FocusedState {
  readonly buckets: Buckets;
  readonly lineage: Lineage;
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
export function stateSig(b: Buckets, lineage?: Lineage): string {
  const h = encodeBucket(b.helper);
  const t = encodeBucket(b.trouble);
  const g = encodeBucket(b.growing);
  const c = encodeBucket(b.complete);
  const base = `${h}|${t}|${g}|${c}`;
  if (lineage === undefined) return base;
  return `${base}@${encodeLineage(lineage)}`;
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
