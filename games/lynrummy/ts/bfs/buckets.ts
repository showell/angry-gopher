// buckets.ts — 4-bucket BFS state shape + boundary helper.
//
// Bucket entries inside the BFS are always ClassifiedCardStack —
// `classifyBuckets` is the boundary that converts a raw `Buckets` of
// card-list stacks into a CCS-shaped one. Inside BFS the "no
// KIND_OTHER" invariant holds by construction.

import type { Card } from "../core/card.ts";
import {
  classifyStack,
  type ClassifiedCardStack,
} from "../core/card_stack.ts";

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

/** Per-state queue used as part of the memoization-signature key
 *  in engine_v2's BFS — see `sigFn` / `queueToLineage`. */
export type Lineage = readonly (readonly Card[])[];

/** Build a position-of-cardId map from a full game's initial state.
 *  Iterates all buckets, collects card-ids in encounter order, and
 *  returns the inverse: posOf[cardId] = position 0..N-1.
 *  Use ONCE per game; pass to fastStateSig on every call. */
export function buildCardOrder(initial: Buckets): {
  cardOrder: readonly number[];
  posOf: Uint8Array;
} {
  const cardId = (c: Card): number => (c.rank - 1) * 8 + c.suit * 2 + c.deck;
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
  const cardId = (c: Card): number => (c.rank - 1) * 8 + c.suit * 2 + c.deck;
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
