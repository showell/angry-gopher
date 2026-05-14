// enumerator.ts — BFS move generator + focus rule.
//
// TS port of python/enumerator.py.
//
// Operates on CCS-shaped Buckets internally; the boundary at the BFS
// entry (`bfs.ts`) classifies raw input once via `classifyBuckets`.
// Descriptors continue to hold raw card tuples for plan-line stability.
//
// Iteration order is the cross-language canon — DON'T rearrange for
// readability. See ENGINE_V2.md § "Iteration order is canon".

import { type Card, isRedSuit } from "../core/card.ts";
import {
  type ClassifiedCardStack,
  type Kind,
  KIND_RUN, KIND_RB, KIND_SET,
  classifyStack,
  successor,
  predecessor,
} from "../core/card_stack.ts";
import {
  peel, pluck, yank, steal, splitOut, setPeel,
  kindAfterAbsorbRight, kindAfterAbsorbLeft,
  extendsTables,
  findSpliceCandidates,
  shapeId,
  type ExtenderMap,
} from "./classified_card_stack.ts";
import {
  type Buckets,
  type BucketName,
} from "./buckets.ts";
import {
  type Move,
  type DecomposeMove,
  type ExtractAbsorbMove,
  type FreePullMove,
  type PushMove,
  type ShiftMove,
  type SpliceMove,
  type Verb,
} from "./move.ts";

// NOTE: classified_card_stack.ts doesn't currently export splice_left or
// splice_right (the splice EXECUTORS used by the BFS). The leaf module
// only exports the probes. The enumerator needs the executors below.
// We import them via a separate re-export at the bottom of this file
// (see "splice executors — local definitions" at the bottom) since
// modifying the leaf module is out of scope per the task brief.

// --- Length-3+ legal kinds. Used by graduate / push / engulf to decide
// whether a merge result has reached a complete group.
const LEGAL_LEN3_KINDS = new Set<Kind>([KIND_RUN, KIND_RB, KIND_SET]);
const RUN_FAMILY_KINDS = new Set<Kind>([KIND_RUN, KIND_RB]);

// --- Bucket transitions (pure helpers) ------------------------------------

function dropAt<T>(stacks: readonly T[], idx: number): T[] {
  return stacks.slice(0, idx).concat(stacks.slice(idx + 1));
}

/** Drop the absorber at (bucketName, idx) from its bucket; the other
 *  bucket passes through unchanged. Returns [newTrouble, newGrowing]. */
function removeAbsorber(
  bucketName: BucketName,
  idx: number,
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
): [ClassifiedCardStack[], ClassifiedCardStack[]] {
  if (bucketName === "trouble") {
    return [dropAt(trouble, idx), [...growing]];
  }
  return [[...trouble], dropAt(growing, idx)];
}

/** If `merged` classifies as a complete legal group (length-3+ run/rb/set),
 *  append it to COMPLETE; otherwise append to GROWING. Returns
 *  [newGrowing, newComplete, graduatedFlag]. */
function graduate(
  merged: ClassifiedCardStack,
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
): [ClassifiedCardStack[], ClassifiedCardStack[], boolean] {
  if (LEGAL_LEN3_KINDS.has(merged.kind)) {
    return [[...growing], [...complete, merged], true];
  }
  return [[...growing, merged], [...complete], false];
}

// --- Doomed-third filter --------------------------------------------------

/** Set of (value*4 + suit) shape ids available as candidate "third
 *  cards" to complete some 2-partial elsewhere on the board. Helper
 *  cards plus trouble singletons. Mirrors python's
 *  `completion_inventory`. */
function completionInventory(
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
): Set<number> {
  const inv = new Set<number>();
  for (const stack of helper) {
    for (const c of stack.cards) {
      inv.add(c.rank * 4 + c.suit);
    }
  }
  for (const stack of trouble) {
    if (stack.n === 1) {
      const c = stack.cards[0]!;
      inv.add(c.rank * 4 + c.suit);
    }
  }
  return inv;
}

/** Return the set of (value*4 + suit) shape ids that would complete a
 *  2-card partial into a legal length-3 stack. Mirrors python's
 *  `completion_shapes`. */
function completionShapes(partial: readonly Card[]): Set<number> {
  const c1 = partial[0]!;
  const c2 = partial[1]!;
  const v1 = c1.rank, s1 = c1.suit;
  const v2 = c2.rank, s2 = c2.suit;
  const out = new Set<number>();
  if (v1 === v2) {
    // Set partial — distinct-suit third of same value.
    for (let s = 0; s < 4; s++) {
      if (s !== s1 && s !== s2) out.add(v1 * 4 + s);
    }
    return out;
  }
  // Run partial: c1, c2 consecutive (c2 = c1's successor).
  const predV = predecessor(v1);
  const succV = successor(v2);
  if (s1 === s2) {
    // Pure run — same-suit extensions on either end.
    out.add(predV * 4 + s1);
    out.add(succV * 4 + s2);
    return out;
  }
  // rb run — opposite-color extensions on either end.
  const s1red = isRedSuit(s1);
  const s2red = isRedSuit(s2);
  for (let s = 0; s < 4; s++) {
    if (isRedSuit(s) !== s1red) out.add(predV * 4 + s);
    if (isRedSuit(s) !== s2red) out.add(succV * 4 + s);
  }
  return out;
}

/** True if NO completion shape for `partial` exists in `inventory` —
 *  the partial is doomed to remain a 2-partial. */
function hasDoomedThird(partial: readonly Card[], inventory: Set<number>): boolean {
  const shapes = completionShapes(partial);
  for (const s of shapes) {
    if (inventory.has(s)) return false;
  }
  return true;
}

/** Gate every absorbed result. `merged` is a CCS — already classified
 *  by its absorb probe. Length-2 results that produce no completion
 *  candidate are inadmissible. */
function admissibleMerged(merged: ClassifiedCardStack, completionInv: Set<number>): boolean {
  if (merged.n === 2 && hasDoomedThird(merged.cards, completionInv)) {
    return false;
  }
  return true;
}

// --- Extract dispatch -----------------------------------------------------

interface ExtractResult {
  readonly newHelper: readonly ClassifiedCardStack[];
  /** Pieces that land in TROUBLE — singletons or doomed-shape
   *  partials the search will work to clear. */
  readonly spawned: readonly ClassifiedCardStack[];
  /** Pieces that land in GROWING — coherent length-2 partials
   *  (today only `set_peel` produces one). */
  readonly spawnedGrowing: readonly ClassifiedCardStack[];
  readonly extCard: Card;
  readonly sourceBeforeCards: readonly Card[];
}

function doExtract(
  helper: readonly ClassifiedCardStack[],
  srcIdx: number,
  ci: number,
  verb: Verb,
): ExtractResult {
  const source = helper[srcIdx]!;
  const sourceBeforeCards = [...source.cards];
  const { helpers: helperPieces, troubleSpawned, growingSpawned } =
    extractPieces(source, ci, verb);
  const newHelper = helper.slice(0, srcIdx)
    .concat(helper.slice(srcIdx + 1))
    .concat(helperPieces);
  return {
    newHelper,
    spawned: troubleSpawned,
    spawnedGrowing: growingSpawned,
    extCard: source.cards[ci]!,
    sourceBeforeCards,
  };
}

interface ExtractedPieces {
  helpers: ClassifiedCardStack[];
  troubleSpawned: ClassifiedCardStack[];
  growingSpawned: ClassifiedCardStack[];
}

function extractPieces(
  source: ClassifiedCardStack,
  ci: number,
  verb: Verb,
): ExtractedPieces {
  if (verb === "peel") {
    const [, remnant] = peel(source, ci);
    return { helpers: [remnant!], troubleSpawned: [], growingSpawned: [] };
  }
  if (verb === "set_peel") {
    const [, remnant] = setPeel(source, ci);
    // The pair_set remnant is a coherent length-2 partial that
    // belongs in GROWING — NOT in helpers (length<3) and NOT in
    // trouble (it's already legitimate growth state).
    return { helpers: [], troubleSpawned: [], growingSpawned: [remnant!] };
  }
  if (verb === "pluck") {
    const [, left, right] = pluck(source, ci);
    return { helpers: [left!, right!], troubleSpawned: [], growingSpawned: [] };
  }
  if (verb === "yank") {
    const [, left, right] = yank(source, ci);
    const helpers: ClassifiedCardStack[] = [];
    const troubleSpawned: ClassifiedCardStack[] = [];
    const growingSpawned: ClassifiedCardStack[] = [];
    for (const piece of [left!, right!]) {
      if (piece.n >= 3) {
        helpers.push(piece);
      } else if (piece.n === 2) {
        // Length-2 yank remnants are coherent pair_run / pair_rb
        // (the yank function preserves the parent run/rb family).
        // They belong in GROWING — the same routing as set_peel's
        // pair_set remnant — so the search doesn't have to fight
        // its way back from a needlessly-shattered state.
        growingSpawned.push(piece);
      } else {
        troubleSpawned.push(piece);
      }
    }
    return { helpers, troubleSpawned, growingSpawned };
  }
  if (verb === "split_out") {
    const [, left, right] = splitOut(source, ci);
    // Both halves are singletons by precondition.
    return { helpers: [], troubleSpawned: [left!, right!], growingSpawned: [] };
  }
  if (verb === "steal") {
    const pieces = steal(source, ci);
    // For sets: rest is N-1 singletons. For run/rb: rest is one
    // length-2 partial. Either way, route to TROUBLE — these are
    // orphan-shape pieces the BFS works to extend or decompose.
    return {
      helpers: [],
      troubleSpawned: pieces.slice(1) as ClassifiedCardStack[],
      growingSpawned: [],
    };
  }
  throw new Error(`unknown verb ${verb}`);
}

interface ExtractableEntry {
  readonly hi: number;
  readonly ci: number;
  readonly verb: Verb;
}

/** One-pass scan over HELPER, building a map from (value*4 + suit)
 *  shape → list of {hi, ci, verb}. The absorber loop inverts the old
 *  per-card-shape-check pattern into direct shape lookup. */
function extractableIndex(
  helper: readonly ClassifiedCardStack[],
): Map<number, ExtractableEntry[]> {
  const out = new Map<number, ExtractableEntry[]>();
  const add = (cards: readonly Card[], ci: number, hi: number, verb: Verb) => {
    const c = cards[ci]!;
    const key = c.rank * 4 + c.suit;
    let arr = out.get(key);
    if (!arr) {
      arr = [];
      out.set(key, arr);
    }
    arr.push({ hi, ci, verb });
  };
  for (let hi = 0; hi < helper.length; hi++) {
    const src = helper[hi]!;
    const kind = src.kind;
    const n = src.n;
    const cards = src.cards;
    if (kind === KIND_RUN || kind === KIND_RB) {
      if (n === 3) {
        add(cards, 0, hi, "steal");
        add(cards, 1, hi, "split_out");
        add(cards, 2, hi, "steal");
      } else {
        const last = n - 1;
        add(cards, 0, hi, "peel");
        add(cards, last, hi, "peel");
        for (let ci = 1; ci < last; ci++) {
          let verb: Verb | null = null;
          if (3 <= ci && ci <= n - 4) {
            verb = "pluck";
          } else if (Math.max(ci, n - ci - 1) >= 3 && Math.min(ci, n - ci - 1) >= 1) {
            verb = "yank";
          }
          if (verb !== null) add(cards, ci, hi, verb);
        }
      }
    } else if (kind === KIND_SET) {
      if (n >= 4) {
        for (let ci = 0; ci < n; ci++) add(cards, ci, hi, "peel");
      } else if (n === 3) {
        // Length-3 SET extraction has TWO live verbs per position:
        //   - `steal`: shatters the SET into 2 trouble singletons
        //   - `set_peel`: keeps the remnant as a pair_set in GROWING
        // Both are kept because they produce genuinely different
        // post-states. The set_peel branch fixes the silly split-
        // then-rejoin pattern (a3_003); the steal branch preserves
        // the singleton-spawn option some scenarios need (e.g. when
        // the two remaining set members can each independently
        // complete different partials elsewhere on the board). A
        // partition by position was tried and dropped — it cut
        // valid plans on 11 scenarios in the broader corpus.
        for (let ci = 0; ci < n; ci++) {
          add(cards, ci, hi, "steal");
          add(cards, ci, hi, "set_peel");
        }
      }
    }
    // KIND_PAIR_RUN / KIND_PAIR_RB / KIND_PAIR_SET / KIND_SINGLETON:
    // nothing extracts. Skip.
  }
  return out;
}

// --- Push / engulf merge primitive ---------------------------------------

/** Sequentially absorb each card in `cardsToAdd` onto the RIGHT of
 *  `target`. Returns the resulting CCS, or null if any step is illegal. */
function absorbSeqRight(
  target: ClassifiedCardStack,
  cardsToAdd: readonly Card[],
): ClassifiedCardStack | null {
  let current = target;
  for (const c of cardsToAdd) {
    const newKind = kindAfterAbsorbRight(current, c);
    if (newKind === null) return null;
    current = { cards: [...current.cards, c], kind: newKind, n: current.n + 1 };
  }
  return current;
}

/** Sequentially absorb each card in `cardsToAdd` onto the LEFT of
 *  `target`. Cards are prepended in REVERSE so the resulting stack is
 *  `cardsToAdd ++ target.cards` (leftmost of cardsToAdd ends up
 *  leftmost). Returns the resulting CCS, or null if any step is illegal. */
function absorbSeqLeft(
  target: ClassifiedCardStack,
  cardsToAdd: readonly Card[],
): ClassifiedCardStack | null {
  let current = target;
  for (let i = cardsToAdd.length - 1; i >= 0; i--) {
    const c = cardsToAdd[i]!;
    const newKind = kindAfterAbsorbLeft(current, c);
    if (newKind === null) return null;
    current = { cards: [c, ...current.cards], kind: newKind, n: current.n + 1 };
  }
  return current;
}

// --- Absorber shapes (earned at commitment point) -------------------------

interface AbsorberShape {
  readonly bucket: BucketName;
  readonly idx: number;
  readonly target: ClassifiedCardStack;
  readonly leftExt: ExtenderMap;
  readonly rightExt: ExtenderMap;
  readonly setExt: ExtenderMap;
}

function buildAbsorberShapes(
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
): AbsorberShape[] {
  const out: AbsorberShape[] = [];
  for (let ti = 0; ti < trouble.length; ti++) {
    const t = trouble[ti]!;
    const [leftExt, rightExt, setExt] = extendsTables(t);
    out.push({ bucket: "trouble", idx: ti, target: t, leftExt, rightExt, setExt });
  }
  for (let gi = 0; gi < growing.length; gi++) {
    const g = growing[gi]!;
    const [leftExt, rightExt, setExt] = extendsTables(g);
    out.push({ bucket: "growing", idx: gi, target: g, leftExt, rightExt, setExt });
  }
  return out;
}

// --- Eligible helpers for splice / shift ----------------------------------

interface IndexedStack {
  readonly hi: number;
  readonly stack: ClassifiedCardStack;
}

function eligibleSpliceHelpers(
  helper: readonly ClassifiedCardStack[],
): IndexedStack[] {
  const out: IndexedStack[] = [];
  for (let hi = 0; hi < helper.length; hi++) {
    const h = helper[hi]!;
    if (h.n >= 4 && RUN_FAMILY_KINDS.has(h.kind)) {
      out.push({ hi, stack: h });
    }
  }
  return out;
}

function eligibleShiftHelpers(
  helper: readonly ClassifiedCardStack[],
): IndexedStack[] {
  const out: IndexedStack[] = [];
  for (let hi = 0; hi < helper.length; hi++) {
    const h = helper[hi]!;
    if (h.n === 3 && RUN_FAMILY_KINDS.has(h.kind)) {
      out.push({ hi, stack: h });
    }
  }
  return out;
}

// --- Move generator -------------------------------------------------------

/** What `enumerateMoves` yields per legal move. */
type MoveYield = readonly [Move, Buckets];

/**
 * Yield every legal 1-line extension. `state` is a Buckets of CCS-shaped
 * stacks. Orchestrates six move-type generators (one per move kind);
 * the body here is dispatch only. Mirrors python's `enumerate_moves`.
 */
export function* enumerateMoves(state: Buckets): Generator<MoveYield> {
  const { helper, trouble, growing, complete } = state;
  const completionInv = completionInventory(helper, trouble);

  if (stateHasDoomedGrowing(growing, completionInv)) {
    return;
  }

  const extractable = extractableIndex(helper);
  const spliceHelpers = eligibleSpliceHelpers(helper);
  const shiftHelpers = eligibleShiftHelpers(helper);
  const absorberShapes = buildAbsorberShapes(trouble, growing);

  for (const absorber of absorberShapes) {
    yield* yieldExtractAbsorbs(
      absorber, helper, trouble, growing, complete,
      extractable, completionInv);
    yield* yieldFreePulls(
      absorber, helper, trouble, growing, complete, completionInv);
    yield* yieldPartialSteals(
      absorber, helper, trouble, growing, complete, completionInv);
  }

  yield* yieldShifts(
    absorberShapes, helper, trouble, growing, complete,
    shiftHelpers, extractable, completionInv);
  yield* yieldSplices(helper, trouble, growing, complete, spliceHelpers);
  yield* yieldPushes(helper, trouble, growing, complete);
  yield* yieldEngulfs(helper, trouble, growing, complete);
  yield* yieldDecomposes(helper, trouble, growing, complete);
}

function stateHasDoomedGrowing(
  growing: readonly ClassifiedCardStack[],
  completionInv: Set<number>,
): boolean {
  for (const g of growing) {
    if (g.n === 2) {
      const shapes = completionShapes(g.cards);
      let alive = false;
      for (const s of shapes) {
        if (completionInv.has(s)) { alive = true; break; }
      }
      if (!alive) return true;
    }
  }
  return false;
}

// --- Move type (a): extract+absorb ---------------------------------------

function* yieldExtractAbsorbs(
  absorber: AbsorberShape,
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
  extractable: Map<number, ExtractableEntry[]>,
  completionInv: Set<number>,
): Generator<MoveYield> {
  const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
  const targetCardsList = [...target.cards];
  let ntBase: ClassifiedCardStack[] | null = null;
  let ng: ClassifiedCardStack[] | null = null;

  // Iterate the sorted union of all three buckets so plan output
  // matches the existing iteration order canon (one absorbing shape,
  // then the next absorbing shape). Action order within each shape:
  // right → left → set.
  const shapeUnion = new Set<number>();
  for (const k of leftExt.keys()) shapeUnion.add(k);
  for (const k of rightExt.keys()) shapeUnion.add(k);
  for (const k of setExt.keys()) shapeUnion.add(k);
  const sortedShapes = [...shapeUnion].sort((a, b) => a - b);

  for (const shape of sortedShapes) {
    const rightKind = rightExt.get(shape) ?? null;
    const leftKind = leftExt.get(shape) ?? null;
    const setKind = setExt.get(shape) ?? null;
    const entries = extractable.get(shape) ?? [];
    for (const { hi, ci, verb } of entries) {
      const extCard = helper[hi]!.cards[ci]!;
      const { newHelper, spawned, spawnedGrowing, sourceBeforeCards } =
        doExtract(helper, hi, ci, verb);
      const spawnedLists = spawned.map(s => [...s.cards]);
      const spawnedGrowingLists = spawnedGrowing.map(s => [...s.cards]);
      if (ntBase === null) {
        const [nt, gg] = removeAbsorber(bucket, idx, trouble, growing);
        ntBase = nt;
        ng = gg;
      }
      const nt = [...ntBase, ...spawned];
      const ngWithSpawn = [...ng!, ...spawnedGrowing];

      // Three modes are disjoint per shape; at most one block fires.
      if (rightKind !== null) {
        const merged = absorbRight(target, extCard, rightKind);
        if (admissibleMerged(merged, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(merged, ngWithSpawn, complete);
          const move: ExtractAbsorbMove = {
            type: "extract_absorb",
            verb,
            source: sourceBeforeCards,
            extCard,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...merged.cards],
            side: "right",
            graduated,
            spawned: spawnedLists,
            spawnedGrowing: spawnedGrowingLists,
          };
          yield [move, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
        }
      }
      if (leftKind !== null) {
        const merged = absorbLeft(target, extCard, leftKind);
        if (admissibleMerged(merged, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(merged, ngWithSpawn, complete);
          const move: ExtractAbsorbMove = {
            type: "extract_absorb",
            verb,
            source: sourceBeforeCards,
            extCard,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...merged.cards],
            side: "left",
            graduated,
            spawned: spawnedLists,
            spawnedGrowing: spawnedGrowingLists,
          };
          yield [move, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
        }
      }
      if (setKind !== null) {
        // Sets are unordered; yield right then left.
        const mergedR = absorbRight(target, extCard, setKind);
        if (admissibleMerged(mergedR, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(mergedR, ngWithSpawn, complete);
          const move: ExtractAbsorbMove = {
            type: "extract_absorb",
            verb,
            source: sourceBeforeCards,
            extCard,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...mergedR.cards],
            side: "right",
            graduated,
            spawned: spawnedLists,
            spawnedGrowing: spawnedGrowingLists,
          };
          yield [move, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
        }
        const mergedL = absorbLeft(target, extCard, setKind);
        if (admissibleMerged(mergedL, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(mergedL, ngWithSpawn, complete);
          const move: ExtractAbsorbMove = {
            type: "extract_absorb",
            verb,
            source: sourceBeforeCards,
            extCard,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...mergedL.cards],
            side: "left",
            graduated,
            spawned: spawnedLists,
            spawnedGrowing: spawnedGrowingLists,
          };
          yield [move, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
        }
      }
    }
  }
}

// --- Move type (a''): steal from a TROUBLE pair onto an absorber --------
//
// "Steal AS from [AS 2S] onto [AC' AD]" — single-motion in the kitchen-
// table sense. Source is a length-2 partial in trouble; one card is
// extracted and absorbed onto the focal partial; the other becomes a
// fresh singleton in trouble.

function* yieldPartialSteals(
  absorber: AbsorberShape,
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
  completionInv: Set<number>,
): Generator<MoveYield> {
  const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
  const targetCardsList = [...target.cards];

  for (let pi = 0; pi < trouble.length; pi++) {
    const partial = trouble[pi]!;
    if (partial.n !== 2) continue;
    // Skip self.
    if (bucket === "trouble" && idx === pi) continue;

    for (let ci = 0; ci < 2; ci++) {
      const extCard = partial.cards[ci]!;
      const otherCard = partial.cards[1 - ci]!;
      const leftover: ClassifiedCardStack = {
        cards: [otherCard], kind: "singleton", n: 1,
      };
      const shape = extCard.rank * 4 + extCard.suit;

      const rightKind = rightExt.get(shape) ?? null;
      const leftKind = leftExt.get(shape) ?? null;
      const setKind = setExt.get(shape) ?? null;
      if (rightKind === null && leftKind === null && setKind === null) continue;

      // Build the new trouble bucket: drop the absorber (if in trouble)
      // AND drop the source partial AND add the leftover singleton.
      const baseTrouble: ClassifiedCardStack[] = [];
      let droppedAbsorber = false;
      let droppedSource = false;
      for (let k = 0; k < trouble.length; k++) {
        if (bucket === "trouble" && idx === k) { droppedAbsorber = true; continue; }
        if (k === pi) { droppedSource = true; continue; }
        baseTrouble.push(trouble[k]!);
      }
      void droppedAbsorber; void droppedSource;
      baseTrouble.push(leftover);

      const ng: ClassifiedCardStack[] = bucket === "growing"
        ? trouble.length === 0 ? [...growing.slice(0, idx), ...growing.slice(idx + 1)]
            : [...growing.slice(0, idx), ...growing.slice(idx + 1)]
        : [...growing];

      const yieldMerge = (merged: ClassifiedCardStack, side: "left" | "right") => {
        if (!admissibleMerged(merged, completionInv)) return;
        const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
        const move: ExtractAbsorbMove = {
          type: "extract_absorb",
          verb: "steal",
          source: [...partial.cards],
          extCard,
          targetBefore: targetCardsList,
          targetBucketBefore: bucket,
          result: [...merged.cards],
          side,
          graduated,
          spawned: [[otherCard]],
          spawnedGrowing: [],
        };
        return [move, { helper: [...helper], trouble: baseTrouble, growing: ngFinal, complete: nc }] as const;
      };

      if (rightKind !== null) {
        const m = absorbRight(target, extCard, rightKind);
        const result = yieldMerge(m, "right");
        if (result) yield result;
      }
      if (leftKind !== null) {
        const m = absorbLeft(target, extCard, leftKind);
        const result = yieldMerge(m, "left");
        if (result) yield result;
      }
      if (setKind !== null) {
        const mR = absorbRight(target, extCard, setKind);
        const r1 = yieldMerge(mR, "right");
        if (r1) yield r1;
        const mL = absorbLeft(target, extCard, setKind);
        const r2 = yieldMerge(mL, "left");
        if (r2) yield r2;
      }
    }
  }
}

// --- Move type (a'): free pull (TROUBLE singleton onto absorber) ---------

function* yieldFreePulls(
  absorber: AbsorberShape,
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
  completionInv: Set<number>,
): Generator<MoveYield> {
  const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
  const targetCardsList = [...target.cards];
  for (let li = 0; li < trouble.length; li++) {
    const looseStack = trouble[li]!;
    if (looseStack.n !== 1) continue;
    if (bucket === "trouble" && li === idx) continue;
    const loose = looseStack.cards[0]!;
    const shapeKey = loose.rank * 4 + loose.suit;
    const leftKind = leftExt.get(shapeKey) ?? null;
    const rightKind = rightExt.get(shapeKey) ?? null;
    const setKind = setExt.get(shapeKey) ?? null;
    if (leftKind === null && rightKind === null && setKind === null) continue;

    const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
    let nt: ClassifiedCardStack[];
    if (bucket === "trouble") {
      const liInBase = li > idx ? li - 1 : li;
      nt = dropAt(ntBase, liInBase);
    } else {
      nt = dropAt(ntBase, li);
    }

    if (rightKind !== null) {
      const merged = absorbRight(target, loose, rightKind);
      if (admissibleMerged(merged, completionInv)) {
        const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
        const move: FreePullMove = {
          type: "free_pull",
          loose,
          targetBefore: targetCardsList,
          targetBucketBefore: bucket,
          result: [...merged.cards],
          side: "right",
          graduated,
        };
        yield [move, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
      }
    }
    if (leftKind !== null) {
      const merged = absorbLeft(target, loose, leftKind);
      if (admissibleMerged(merged, completionInv)) {
        const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
        const move: FreePullMove = {
          type: "free_pull",
          loose,
          targetBefore: targetCardsList,
          targetBucketBefore: bucket,
          result: [...merged.cards],
          side: "left",
          graduated,
        };
        yield [move, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
      }
    }
    if (setKind !== null) {
      const mergedR = absorbRight(target, loose, setKind);
      if (admissibleMerged(mergedR, completionInv)) {
        const [ngFinal, nc, graduated] = graduate(mergedR, ng, complete);
        const move: FreePullMove = {
          type: "free_pull",
          loose,
          targetBefore: targetCardsList,
          targetBucketBefore: bucket,
          result: [...mergedR.cards],
          side: "right",
          graduated,
        };
        yield [move, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
      }
      const mergedL = absorbLeft(target, loose, setKind);
      if (admissibleMerged(mergedL, completionInv)) {
        const [ngFinal, nc, graduated] = graduate(mergedL, ng, complete);
        const move: FreePullMove = {
          type: "free_pull",
          loose,
          targetBefore: targetCardsList,
          targetBucketBefore: bucket,
          result: [...mergedL.cards],
          side: "left",
          graduated,
        };
        yield [move, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
      }
    }
  }
}

// --- Move type (d): SHIFT -------------------------------------------------

function* yieldShifts(
  absorberShapes: readonly AbsorberShape[],
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
  shiftHelpers: readonly IndexedStack[],
  extractable: Map<number, ExtractableEntry[]>,
  completionInv: Set<number>,
): Generator<MoveYield> {
  for (const absorber of absorberShapes) {
    for (const { hi: srcIdx, stack: source } of shiftHelpers) {
      for (const whichEnd of [0, 2] as const) {
        yield* yieldShiftsForEndpoint(
          absorber, helper, trouble, growing, complete,
          srcIdx, source, whichEnd, extractable, completionInv);
      }
    }
  }
}

function shiftReplacementRequirement(
  source: ClassifiedCardStack,
  whichEnd: number,
): { pValue: number; neededSuits: readonly number[] } {
  let anchor: Card;
  let pValue: number;
  if (whichEnd === 2) {
    anchor = source.cards[0]!;
    pValue = predecessor(anchor.rank);
  } else {
    anchor = source.cards[2]!;
    pValue = successor(anchor.rank);
  }
  const anchorRed = isRedSuit(anchor.suit);
  let neededSuits: number[];
  if (source.kind === KIND_RUN) {
    neededSuits = [anchor.suit];
  } else {
    neededSuits = [];
    for (let s = 0; s < 4; s++) {
      if (isRedSuit(s) !== anchorRed) neededSuits.push(s);
    }
  }
  return { pValue, neededSuits };
}

function shiftDonorCandidates(
  helper: readonly ClassifiedCardStack[],
  srcIdx: number,
  pValue: number,
  neededSuits: readonly number[],
  extractable: Map<number, ExtractableEntry[]>,
): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  for (const pSuit of neededSuits) {
    const entries = extractable.get(pValue * 4 + pSuit) ?? [];
    for (const { hi: donorIdx, ci, verb } of entries) {
      if (verb === "peel" && donorIdx !== srcIdx && helper[donorIdx]!.n >= 4) {
        out.push([donorIdx, ci]);
      }
    }
  }
  // Sort by (donor_idx, ci) for deterministic iteration.
  out.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  return out;
}

function shiftRebuildSource(
  source: ClassifiedCardStack,
  pCard: Card,
  whichEnd: number,
): ClassifiedCardStack | null {
  let newCards: Card[];
  if (whichEnd === 2) {
    newCards = [pCard, source.cards[0]!, source.cards[1]!];
  } else {
    newCards = [source.cards[1]!, source.cards[2]!, pCard];
  }
  return classifyStack(newCards);
}

function shiftRebuildHelper(
  helper: readonly ClassifiedCardStack[],
  srcIdx: number,
  donorIdx: number,
  newSource: ClassifiedCardStack,
  newDonor: ClassifiedCardStack,
): ClassifiedCardStack[] {
  let nh = [...helper];
  // Drop both src and donor (descending so removals don't shift each other).
  const indices = [srcIdx, donorIdx].sort((a, b) => b - a);
  for (const i of indices) nh = dropAt(nh, i);
  return [...nh, newSource, newDonor];
}

function* yieldShiftsForEndpoint(
  absorber: AbsorberShape,
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
  srcIdx: number,
  source: ClassifiedCardStack,
  whichEnd: number,
  extractable: Map<number, ExtractableEntry[]>,
  completionInv: Set<number>,
): Generator<MoveYield> {
  const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
  const stolen = source.cards[whichEnd]!;
  const shapeKey = stolen.rank * 4 + stolen.suit;
  const leftKind = leftExt.get(shapeKey) ?? null;
  const rightKind = rightExt.get(shapeKey) ?? null;
  const setKind = setExt.get(shapeKey) ?? null;
  if (leftKind === null && rightKind === null && setKind === null) return;
  const { pValue, neededSuits } = shiftReplacementRequirement(source, whichEnd);
  const candidates = shiftDonorCandidates(helper, srcIdx, pValue, neededSuits, extractable);
  for (const [donorIdx, ci] of candidates) {
    const donor = helper[donorIdx]!;
    const pCard = donor.cards[ci]!;
    const [, newDonor] = peel(donor, ci);
    const newSource = shiftRebuildSource(source, pCard, whichEnd);
    if (newSource === null || newSource.kind !== source.kind) continue;
    const nh = shiftRebuildHelper(helper, srcIdx, donorIdx, newSource, newDonor!);

    if (rightKind !== null) {
      const merged = absorbRight(target, stolen, rightKind);
      if (admissibleMerged(merged, completionInv)) {
        const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
        const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
        const move: ShiftMove = {
          type: "shift",
          source: [...source.cards],
          donor: [...donor.cards],
          stolen,
          pCard,
          whichEnd,
          newSource: [...newSource.cards],
          newDonor: [...newDonor!.cards],
          targetBefore: [...target.cards],
          targetBucketBefore: bucket,
          merged: [...merged.cards],
          side: "right",
          graduated,
        };
        yield [move, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
      }
    }
    if (leftKind !== null) {
      const merged = absorbLeft(target, stolen, leftKind);
      if (admissibleMerged(merged, completionInv)) {
        const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
        const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
        const move: ShiftMove = {
          type: "shift",
          source: [...source.cards],
          donor: [...donor.cards],
          stolen,
          pCard,
          whichEnd,
          newSource: [...newSource.cards],
          newDonor: [...newDonor!.cards],
          targetBefore: [...target.cards],
          targetBucketBefore: bucket,
          merged: [...merged.cards],
          side: "left",
          graduated,
        };
        yield [move, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
      }
    }
    if (setKind !== null) {
      const mergedR = absorbRight(target, stolen, setKind);
      if (admissibleMerged(mergedR, completionInv)) {
        const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
        const [ngFinal, nc, graduated] = graduate(mergedR, ng, complete);
        const move: ShiftMove = {
          type: "shift",
          source: [...source.cards],
          donor: [...donor.cards],
          stolen,
          pCard,
          whichEnd,
          newSource: [...newSource.cards],
          newDonor: [...newDonor!.cards],
          targetBefore: [...target.cards],
          targetBucketBefore: bucket,
          merged: [...mergedR.cards],
          side: "right",
          graduated,
        };
        yield [move, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
      }
      const mergedL = absorbLeft(target, stolen, setKind);
      if (admissibleMerged(mergedL, completionInv)) {
        const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
        const [ngFinal, nc, graduated] = graduate(mergedL, ng, complete);
        const move: ShiftMove = {
          type: "shift",
          source: [...source.cards],
          donor: [...donor.cards],
          stolen,
          pCard,
          whichEnd,
          newSource: [...newSource.cards],
          newDonor: [...newDonor!.cards],
          targetBefore: [...target.cards],
          targetBucketBefore: bucket,
          merged: [...mergedL.cards],
          side: "left",
          graduated,
        };
        yield [move, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
      }
    }
  }
}

// --- Move type (c): splice ------------------------------------------------

function* yieldSplices(
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
  spliceHelpers: readonly IndexedStack[],
): Generator<MoveYield> {
  let growingSnapshot: ClassifiedCardStack[] | null = null;
  let completeSnapshot: ClassifiedCardStack[] | null = null;
  for (let ti = 0; ti < trouble.length; ti++) {
    const t = trouble[ti]!;
    if (t.n !== 1) continue;
    const loose = t.cards[0]!;
    for (const { hi, stack: src } of spliceHelpers) {
      for (const cand of findSpliceCandidates(src, loose)) {
        let left: ClassifiedCardStack;
        let right: ClassifiedCardStack;
        if (cand.side === "left") {
          [left, right] = splice_left(
            src, loose, cand.position, cand.leftKind, cand.rightKind);
        } else {
          [left, right] = splice_right(
            src, loose, cand.position, cand.leftKind, cand.rightKind);
        }
        const nh = [...dropAt(helper, hi), left, right];
        const nt = dropAt(trouble, ti);
        if (growingSnapshot === null) {
          growingSnapshot = [...growing];
          completeSnapshot = [...complete];
        }
        const move: SpliceMove = {
          type: "splice",
          loose,
          source: [...src.cards],
          k: cand.position,
          side: cand.side,
          leftResult: [...left.cards],
          rightResult: [...right.cards],
        };
        yield [move, { helper: nh, trouble: nt, growing: [...growingSnapshot], complete: [...completeSnapshot!] }];
      }
    }
  }
}

// --- Move type (b): push TROUBLE onto HELPER -----------------------------

function* yieldPushes(
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
): Generator<MoveYield> {
  for (let ti = 0; ti < trouble.length; ti++) {
    const t = trouble[ti]!;
    if (t.n > 2) continue;
    for (let hi = 0; hi < helper.length; hi++) {
      const h = helper[hi]!;
      // RIGHT push.
      const mergedR = absorbSeqRight(h, t.cards);
      if (mergedR !== null) {
        const nh = [...dropAt(helper, hi), mergedR];
        const nt = dropAt(trouble, ti);
        const move: PushMove = {
          type: "push",
          troubleBefore: [...t.cards],
          targetBefore: [...h.cards],
          result: [...mergedR.cards],
          side: "right",
        };
        yield [move, { helper: nh, trouble: nt, growing: [...growing], complete: [...complete] }];
      }
      // LEFT push.
      const mergedL = absorbSeqLeft(h, t.cards);
      if (mergedL !== null) {
        const nh = [...dropAt(helper, hi), mergedL];
        const nt = dropAt(trouble, ti);
        const move: PushMove = {
          type: "push",
          troubleBefore: [...t.cards],
          targetBefore: [...h.cards],
          result: [...mergedL.cards],
          side: "left",
        };
        yield [move, { helper: nh, trouble: nt, growing: [...growing], complete: [...complete] }];
      }
    }
  }
}

// --- Move type (b'): GROWING engulfs HELPER ------------------------------

function* yieldEngulfs(
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
): Generator<MoveYield> {
  for (let gi = 0; gi < growing.length; gi++) {
    const g = growing[gi]!;
    for (let hi = 0; hi < helper.length; hi++) {
      const h = helper[hi]!;
      const mergedR = absorbSeqRight(h, g.cards);
      if (mergedR !== null) {
        const nh = dropAt(helper, hi);
        const ng = dropAt(growing, gi);
        const nc = [...complete, mergedR];
        const move: PushMove = {
          type: "push",
          troubleBefore: [...g.cards],
          targetBefore: [...h.cards],
          result: [...mergedR.cards],
          side: "right",
        };
        yield [move, { helper: nh, trouble: [...trouble], growing: ng, complete: nc }];
      }
      const mergedL = absorbSeqLeft(h, g.cards);
      if (mergedL !== null) {
        const nh = dropAt(helper, hi);
        const ng = dropAt(growing, gi);
        const nc = [...complete, mergedL];
        const move: PushMove = {
          type: "push",
          troubleBefore: [...g.cards],
          targetBefore: [...h.cards],
          result: [...mergedL.cards],
          side: "left",
        };
        yield [move, { helper: nh, trouble: [...trouble], growing: ng, complete: nc }];
      }
    }
  }
}

// --- Decompose: split a TROUBLE pair back into its singletons ------------
//
// The bundling that pair-spawning moves (steal/yank/split/etc.) produce
// isn't a real game commitment. Sometimes the right play separates the
// cards. This move expresses that. See `random233.md` for the discovery.
//
// We only decompose pairs in TROUBLE (not GROWING). A GROWING pair is
// under active extension via lineage; decomposing it would discard the
// in-progress work. A TROUBLE pair has no such lineage commitment.

function* yieldDecomposes(
  helper: readonly ClassifiedCardStack[],
  trouble: readonly ClassifiedCardStack[],
  growing: readonly ClassifiedCardStack[],
  complete: readonly ClassifiedCardStack[],
): Generator<MoveYield> {
  for (let ti = 0; ti < trouble.length; ti++) {
    const t = trouble[ti]!;
    if (t.n !== 2) continue;
    const left = t.cards[0]!;
    const right = t.cards[1]!;
    const leftSingle: ClassifiedCardStack = { cards: [left], kind: "singleton", n: 1 };
    const rightSingle: ClassifiedCardStack = { cards: [right], kind: "singleton", n: 1 };
    const newTrouble = [...trouble.slice(0, ti), ...trouble.slice(ti + 1), leftSingle, rightSingle];
    const move: DecomposeMove = {
      type: "decompose",
      pairBefore: [...t.cards],
      leftCard: left,
      rightCard: right,
    };
    yield [move, { helper: [...helper], trouble: newTrouble, growing: [...growing], complete: [...complete] }];
  }
}

// --- Local absorb executors ----------------------------------------------
//
// The leaf module exports the absorb PROBES (kindAfterAbsorbRight/Left)
// and SPLICE PROBES, but NOT the absorb executors or splice executors.
// Per the task brief, "no changes to existing TS leaves" — so we
// implement these executors locally here (they're trivial wrappers that
// build the new CCS shape from precomputed kind + card list).
//
// An absorb executor is a 1-line builder: prepend or append the card
// and tag with the precomputed result-kind. No reclassification.

function absorbRight(
  target: ClassifiedCardStack,
  card: Card,
  newKind: Kind,
): ClassifiedCardStack {
  return { cards: [...target.cards, card], kind: newKind, n: target.n + 1 };
}

function absorbLeft(
  target: ClassifiedCardStack,
  card: Card,
  newKind: Kind,
): ClassifiedCardStack {
  return { cards: [card, ...target.cards], kind: newKind, n: target.n + 1 };
}

// --- Local splice executors ---------------------------------------------
//
// Mirror python's `splice_left` and `splice_right`. Each takes a parent
// stack, the inserted card, the position, and the precomputed
// (left_kind, right_kind) from the candidate; returns [leftHalf,
// rightHalf]. No reclassification.

function splice_left(
  stack: ClassifiedCardStack,
  card: Card,
  position: number,
  leftKind: Kind,
  rightKind: Kind,
): readonly [ClassifiedCardStack, ClassifiedCardStack] {
  const leftCards: Card[] = stack.cards.slice(0, position).concat([card]);
  const rightCards: Card[] = stack.cards.slice(position);
  return [
    { cards: leftCards, kind: leftKind, n: leftCards.length },
    { cards: rightCards, kind: rightKind, n: rightCards.length },
  ];
}

function splice_right(
  stack: ClassifiedCardStack,
  card: Card,
  position: number,
  leftKind: Kind,
  rightKind: Kind,
): readonly [ClassifiedCardStack, ClassifiedCardStack] {
  const leftCards: Card[] = stack.cards.slice(0, position);
  const rightCards: Card[] = [card, ...stack.cards.slice(position)];
  return [
    { cards: leftCards, kind: leftKind, n: leftCards.length },
    { cards: rightCards, kind: rightKind, n: rightCards.length },
  ];
}

// `shapeId` is exported by classified_card_stack.ts; re-exposed here
// only when callers (e.g., tests) need to construct probe inputs by
// shape. Not used internally.
export { shapeId };
