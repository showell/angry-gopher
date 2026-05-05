// verbs.ts — verb→primitive expansion.
//
// One pass. Honest state. The agent walks the solver's verbs and emits
// the primitive sequence a human at the kitchen table would: at every
// merge, glance at the participants — is this card in my hand or on
// the table? Is there room where the merged stack lands? — and pick
// the move accordingly.
//
// Three rules baked into the helpers:
//
//   R1 (hand-direct): if a verb names a single card that's in
//   `pendingHand`, the merge is a direct hand-to-stack drag
//   (`merge_hand`), not place-then-merge.
//
//   R2 (small→large): for board-to-board merges, the smaller stack
//   is the one that physically moves. If the solver named the larger
//   stack as source, swap source↔target and flip side. The merged
//   content is identical.
//
//   R3 (don't move if there's room): a merge or end-split pre-flights
//   only when the post-action board would actually violate the legal
//   threshold (`findCrowding`). Interior splits pre-flight
//   unconditionally per Steve, 2026-04-23 — siblings of an interior
//   split need a 4-side-clear region for downstream primitives to
//   build on.
//
// The per-verb functions stay short: they describe the verb's
// structure (split here, merge there) and let the helpers handle the
// physical decisions.

import type { Card } from "./rules/card.ts";
import type {
  Desc, Side,
  ExtractAbsorbDesc, FreePullDesc, PushDesc,
  ShiftDesc, SpliceDesc, DecomposeDesc,
} from "./move.ts";
import {
  type BoardStack, type Loc,
  CARD_PITCH, findOpenLoc, findCrowding,
  stackRect, padRect, rectsOverlap, PLANNING_MARGIN,
} from "./geometry.ts";
import {
  type Primitive, type SplitPrim, type MergeStackPrim, type MergeHandPrim, type MoveStackPrim,
  applyLocally, findStackIndex,
} from "./primitives.ts";
import { classifyStack } from "./classified_card_stack.ts";

function flipSide(s: Side): Side {
  return s === "left" ? "right" : "left";
}

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

/** Walk a verb's structure and emit the physical primitives.
 *  `pendingHand` is the set of card-keys still in the player's hand
 *  for this play; passing an empty set treats every singleton the verb
 *  names as already-on-board (the per-verb DSL test surface). */
export function expandVerb(
  desc: Desc,
  board: readonly BoardStack[],
  pendingHand: ReadonlySet<string> = new Set(),
): Primitive[] {
  switch (desc.type) {
    case "extract_absorb": return extractAbsorbPrims(desc, board, pendingHand);
    case "free_pull":      return freePullPrims(desc, board, pendingHand);
    case "push":           return pushPrims(desc, board, pendingHand);
    case "splice":         return splicePrims(desc, board, pendingHand);
    case "shift":          return shiftPrims(desc, board, pendingHand);
    case "decompose":      return decomposePrims(desc, board);
  }
}

/** Per-verb DSL test surface. No hand awareness — every card the verb
 *  names is treated as already on the board. */
export function moveToPrimitives(
  desc: Desc,
  board: readonly BoardStack[],
): readonly Primitive[] {
  return expandVerb(desc, board, new Set());
}

// --- Primitive emission helpers ---------------------------------------

/** Emit a split. For end-splits, probe the post-board and pre-flight
 *  only when needed. For interior splits, pre-flight unconditionally. */
function planSplitAfter(
  sim: readonly BoardStack[],
  stackContent: readonly Card[],
  k: number,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const n = stackContent.length;
  if (!(k >= 1 && k <= n - 1)) {
    throw new Error(`split-after k=${k} out of range for n=${n}`);
  }
  // Mirror applySplit's left_count derivation: ci=k-1 if k <= n/2, else ci=k.
  const ci = k <= Math.floor(n / 2) ? k - 1 : k;
  const si = findStackIndex(sim, stackContent);
  const isInterior = ci !== 0 && ci !== n - 1;

  // Interior splits: always relocate source to a 4-side-clear region.
  // Siblings will sit in tight quarters that downstream primitives
  // can't safely build on.
  if (isInterior) {
    const others = sim.filter((_, i) => i !== si);
    const newLoc = findOpenLoc(others, n);
    const cur = sim[si]!.loc;
    if (newLoc.top !== cur.top || newLoc.left !== cur.left) {
      const move: MoveStackPrim = { action: "move_stack", stackIndex: si, newLoc };
      const afterMove = applyLocally(sim, move);
      const newSi = findStackIndex(afterMove, stackContent);
      const split: SplitPrim = { action: "split", stackIndex: newSi, cardIndex: ci };
      const post = applyLocally(afterMove, split);
      return { prims: [move, split], sim: post };
    }
  }

  // End-split (or interior-already-clear): try in place.
  const split: SplitPrim = { action: "split", stackIndex: si, cardIndex: ci };
  const post = applyLocally(sim, split);
  if (findCrowding(post) === null) {
    return { prims: [split], sim: post };
  }
  // End-split needs room. Move source first.
  const others = sim.filter((_, i) => i !== si);
  const newLoc = findOpenLoc(others, n);
  const cur = sim[si]!.loc;
  if (newLoc.top === cur.top && newLoc.left === cur.left) {
    // No better spot exists — emit as-is.
    return { prims: [split], sim: post };
  }
  const move: MoveStackPrim = { action: "move_stack", stackIndex: si, newLoc };
  const afterMove = applyLocally(sim, move);
  const newSi = findStackIndex(afterMove, stackContent);
  const newSplit: SplitPrim = { action: "split", stackIndex: newSi, cardIndex: ci };
  const post2 = applyLocally(afterMove, newSplit);
  return { prims: [move, newSplit], sim: post2 };
}

/** Emit a merge. R1 (hand-direct), R2 (small→large), R3 (don't move
 *  if there's room) all live here. */
function planMerge(
  sim: readonly BoardStack[],
  srcContent: readonly Card[],
  tgtContent: readonly Card[],
  side: Side,
  pendingHand: ReadonlySet<string>,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  // R1a: src is a hand-card singleton — drag it directly onto tgt.
  if (srcContent.length === 1 && pendingHand.has(cardKey(srcContent[0]!))) {
    return planMergeHand(sim, srcContent[0]!, tgtContent, side);
  }
  // R1b: tgt is a hand-card singleton — drag it directly onto src,
  // flipping side so the cards land in the same order. (See the
  // shared invariant above `applyMergeStack` in primitives.ts.)
  if (tgtContent.length === 1 && pendingHand.has(cardKey(tgtContent[0]!))) {
    return planMergeHand(sim, tgtContent[0]!, srcContent, flipSide(side));
  }
  // R2: both on board — physically drag the smaller stack onto the
  // larger. The merged content is identical regardless of direction.
  let s = srcContent, t = tgtContent, sd = side;
  if (s.length > t.length) {
    [s, t] = [t, s];
    sd = flipSide(sd);
  }
  return planMergeStackOnBoard(sim, s, t, sd);
}

/** Emit a hand-to-stack merge. R3: only pre-flight if the in-place
 *  result would actually violate the legal threshold. */
function planMergeHand(
  sim: readonly BoardStack[],
  handCard: Card,
  tgtContent: readonly Card[],
  side: Side,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const tgtIdx = findStackIndex(sim, tgtContent);
  const merge: MergeHandPrim = {
    action: "merge_hand", targetStack: tgtIdx, handCard, side,
  };
  const post = applyLocally(sim, merge);
  if (findCrowding(post) === null) {
    return { prims: [merge], sim: post };
  }
  // Pre-flight: relocate tgt so the post-merge stack lands clear.
  const finalSize = tgtContent.length + 1;
  const others = sim.filter((_, i) => i !== tgtIdx);
  const finalLoc = findOpenLoc(others, finalSize);
  // For side=left the hand card joins the LEFT edge — final stack's
  // left = finalLoc.left, so tgt's pre-merge left shifts right by
  // one CARD_PITCH from finalLoc.
  const targetLoc: Loc = side === "left"
    ? { top: finalLoc.top, left: finalLoc.left + CARD_PITCH }
    : finalLoc;
  const cur = sim[tgtIdx]!.loc;
  if (targetLoc.top === cur.top && targetLoc.left === cur.left) {
    // findOpenLoc returned the current spot. Emit merge as-is.
    return { prims: [merge], sim: post };
  }
  const move: MoveStackPrim = {
    action: "move_stack", stackIndex: tgtIdx, newLoc: targetLoc,
  };
  const afterMove = applyLocally(sim, move);
  const newTgtIdx = findStackIndex(afterMove, tgtContent);
  const newMerge: MergeHandPrim = {
    action: "merge_hand", targetStack: newTgtIdx, handCard, side,
  };
  const post2 = applyLocally(afterMove, newMerge);
  return { prims: [move, newMerge], sim: post2 };
}

/** Emit a board-to-board merge. R3: only pre-flight if the in-place
 *  result would violate the legal threshold. Source stays in `others`
 *  during the move/merge intermediate frame because it's physically
 *  still on the board until the merge consumes it. */
export function planMergeStackOnBoard(
  sim: readonly BoardStack[],
  srcContent: readonly Card[],
  tgtContent: readonly Card[],
  side: Side,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const srcIdx = findStackIndex(sim, srcContent);
  const tgtIdx = findStackIndex(sim, tgtContent);
  const merge: MergeStackPrim = {
    action: "merge_stack", sourceStack: srcIdx, targetStack: tgtIdx, side,
  };
  const post = applyLocally(sim, merge);
  if (findCrowding(post) === null) {
    return { prims: [merge], sim: post };
  }
  const finalSize = srcContent.length + tgtContent.length;
  const others = sim.filter((_, i) => i !== tgtIdx);
  const finalLoc = findOpenLoc(others, finalSize);
  const targetLoc: Loc = side === "left"
    ? {
        top: finalLoc.top,
        left: finalLoc.left + CARD_PITCH * srcContent.length,
      }
    : finalLoc;
  const cur = sim[tgtIdx]!.loc;
  if (targetLoc.top === cur.top && targetLoc.left === cur.left) {
    return { prims: [merge], sim: post };
  }
  const move: MoveStackPrim = {
    action: "move_stack", stackIndex: tgtIdx, newLoc: targetLoc,
  };
  const afterMove = applyLocally(sim, move);
  const newSrcIdx = findStackIndex(afterMove, srcContent);
  const newTgtIdx = findStackIndex(afterMove, tgtContent);
  const newMerge: MergeStackPrim = {
    action: "merge_stack",
    sourceStack: newSrcIdx, targetStack: newTgtIdx, side,
  };
  const post2 = applyLocally(afterMove, newMerge);
  return { prims: [move, newMerge], sim: post2 };
}

// --- LeafKind classifier ----------------------------------------------

type LeafKind = "set" | "pure_run" | "rb_run" | "other";
function classifyLeaf(cards: readonly Card[]): LeafKind {
  const ccs = classifyStack(cards);
  if (ccs === null || ccs.n < 3) return "other";
  if (ccs.kind === "set") return "set";
  if (ccs.kind === "run") return "pure_run";
  if (ccs.kind === "rb") return "rb_run";
  return "other";
}

// --- extract + absorb -------------------------------------------------

/** Generate the splits needed to leave the card at index `ci` of
 *  `stackContent` as a singleton. Returns prims, post-sim, the ext
 *  singleton card, and the remnant pieces (1 for end-extraction; 2 for
 *  interior). */
function isolateCard(
  sim: readonly BoardStack[],
  stackContent: readonly Card[],
  ci: number,
): {
  prims: Primitive[];
  sim: readonly BoardStack[];
  extSingleton: readonly Card[];
  remnants: readonly (readonly Card[])[];
} {
  const n = stackContent.length;
  const extCard = stackContent[ci]!;
  const out: Primitive[] = [];

  if (ci === 0 && n > 1) {
    const r = planSplitAfter(sim, stackContent, 1);
    out.push(...r.prims);
    return {
      prims: out, sim: r.sim, extSingleton: [extCard],
      remnants: [stackContent.slice(1)],
    };
  }
  if (ci === n - 1 && n > 1) {
    const r = planSplitAfter(sim, stackContent, n - 1);
    out.push(...r.prims);
    return {
      prims: out, sim: r.sim, extSingleton: [extCard],
      remnants: [stackContent.slice(0, n - 1)],
    };
  }
  // Interior: split after ci → [s[:ci]], [s[ci:]]; then split
  // [s[ci:]] after 1 → [s[ci]] + [s[ci+1:]].
  //
  // Single up-front geometry decision (per Steve's human idiom):
  // relocate the SOURCE up front if the in-place split-split would
  // crowd, otherwise do both splits in place. Never put a move_stack
  // BETWEEN the two splits — a human player wouldn't relocate the
  // residue mid-yank, they'd do both clicks in the same area or
  // move the whole stack first.
  const r = planInteriorIsolate(sim, stackContent, ci);
  out.push(...r.prims);
  return {
    prims: out, sim: r.sim, extSingleton: [extCard],
    remnants: [stackContent.slice(0, ci), stackContent.slice(ci + 1)],
  };
}

/** Two-splits-as-a-unit. Try in place; if the post-state would
 *  be crowded WITH RESPECT TO OTHER STACKS, relocate the source up
 *  front and do both splits at the new loc. Crowding among the
 *  three split products themselves is expected (the per-split
 *  auto-displacement keeps them close by design — that's a human
 *  player's natural shape) and is NOT counted. Both branches emit
 *  two splits sequentially; what differs is whether a single
 *  move_stack precedes them. */
function planInteriorIsolate(
  sim: readonly BoardStack[],
  stackContent: readonly Card[],
  ci: number,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const inPlace = doTwoSplitsAt(sim, stackContent, ci);

  // Identify the three split products by content. Crowding INSIDE
  // this set is expected and ignored; only crowding WITH a stack
  // outside the set means the source's neighborhood was already
  // populated and we need to relocate.
  const productContents: readonly (readonly Card[])[] = [
    stackContent.slice(0, ci),
    [stackContent[ci]!],
    stackContent.slice(ci + 1),
  ];
  const productIndices = new Set<number>();
  for (let i = 0; i < inPlace.sim.length; i++) {
    const s = inPlace.sim[i]!;
    for (const pc of productContents) {
      if (sameContent(s.cards, pc)) {
        productIndices.add(i);
        break;
      }
    }
  }
  if (!hasExternalCrowding(inPlace.sim, productIndices)) {
    return inPlace;
  }

  // External crowding: relocate source up front, then both splits
  // at the new home.
  const n = stackContent.length;
  const si = findStackIndex(sim, stackContent);
  const others = sim.filter((_, i) => i !== si);
  const newLoc = findOpenLoc(others, n);
  const cur = sim[si]!.loc;
  if (newLoc.top === cur.top && newLoc.left === cur.left) {
    return inPlace;
  }
  const move: MoveStackPrim = { action: "move_stack", stackIndex: si, newLoc };
  const afterMove = applyLocally(sim, move);
  const splits = doTwoSplitsAt(afterMove, stackContent, ci);
  return { prims: [move, ...splits.prims], sim: splits.sim };
}

function sameContent(a: readonly Card[], b: readonly Card[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const ca = a[i]!;
    const cb = b[i]!;
    if (ca[0] !== cb[0] || ca[1] !== cb[1] || ca[2] !== cb[2]) return false;
  }
  return true;
}

/** Crowding check that ignores pairs where BOTH stacks are in
 *  `exempt` (the split-product set). Returns true iff at least one
 *  pair involving a non-exempt stack is too close. */
function hasExternalCrowding(
  board: readonly BoardStack[],
  exempt: ReadonlySet<number>,
): boolean {
  const rects = board.map(stackRect);
  for (let i = 0; i < rects.length; i++) {
    const paddedI = padRect(rects[i]!, PLANNING_MARGIN);
    for (let j = i + 1; j < rects.length; j++) {
      if (exempt.has(i) && exempt.has(j)) continue;
      if (rectsOverlap(paddedI, rects[j]!)) return true;
    }
  }
  return false;
}

/** Emit both splits without any geometry pre-flight. The cardIndex
 *  derivations mirror `planSplitAfter`'s "split-after k" → applySplit
 *  cardIndex convention. Returns the prim pair + the post-sim. */
function doTwoSplitsAt(
  sim: readonly BoardStack[],
  stackContent: readonly Card[],
  ci: number,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const n = stackContent.length;
  // Split A: split-after k=ci → left = [s[:ci]], right = [s[ci:]].
  const kA = ci;
  const ciA = kA <= Math.floor(n / 2) ? kA - 1 : kA;
  const siA = findStackIndex(sim, stackContent);
  const splitA: SplitPrim = { action: "split", stackIndex: siA, cardIndex: ciA };
  const afterA = applyLocally(sim, splitA);

  // Split B: from right chunk = [s[ci:]], split-after k=1 →
  // left = [s[ci]], right = [s[ci+1:]].
  const rightChunk = stackContent.slice(ci);
  const nB = rightChunk.length;
  const kB = 1;
  const ciB = kB <= Math.floor(nB / 2) ? kB - 1 : kB;
  const siB = findStackIndex(afterA, rightChunk);
  const splitB: SplitPrim = { action: "split", stackIndex: siB, cardIndex: ciB };
  const afterB = applyLocally(afterA, splitB);

  return { prims: [splitA, splitB], sim: afterB };
}

function indexOfCard(arr: readonly Card[], target: Card): number {
  for (let i = 0; i < arr.length; i++) {
    const c = arr[i]!;
    if (c[0] === target[0] && c[1] === target[1] && c[2] === target[2]) return i;
  }
  return -1;
}

function extractAbsorbPrims(
  desc: ExtractAbsorbDesc,
  board: readonly BoardStack[],
  pendingHand: ReadonlySet<string>,
): Primitive[] {
  const source = desc.source;
  const extCard = desc.extCard;
  const targetBefore = desc.targetBefore;
  const side = desc.side;
  const verb = desc.verb;
  const kind = classifyLeaf(source);
  const ci = indexOfCard(source, extCard);

  let sim: readonly BoardStack[] = board;
  const out: Primitive[] = [];
  let extSingleton: readonly Card[] = [extCard];

  if (verb === "peel" || verb === "pluck" || verb === "yank" || verb === "split_out" || verb === "set_peel") {
    const iso = isolateCard(sim, source, ci);
    out.push(...iso.prims);
    sim = iso.sim;
    extSingleton = iso.extSingleton;

    // Set peel from interior position: remnant comes back as TWO
    // physical pieces; merge them so the set [a, b, d] is one stack.
    // Same merge applies whether the verb is `peel` (length-4+ set,
    // interior position) or `set_peel` (length-3 set, middle card).
    if (kind === "set" && iso.remnants.length === 2) {
      const [leftChunk, tailChunk] = iso.remnants;
      const r = planMerge(sim, tailChunk!, leftChunk!, "right", pendingHand);
      out.push(...r.prims);
      sim = r.sim;
    }
  } else if (verb === "steal" && (kind === "pure_run" || kind === "rb_run")) {
    const iso = isolateCard(sim, source, ci);
    out.push(...iso.prims);
    sim = iso.sim;
    extSingleton = iso.extSingleton;
  } else if (verb === "steal" && kind === "set") {
    // Detach extCard FIRST (split at the end where it sits), then
    // dismantle the same-value pair so subsequent BFS-planned moves
    // (push spawned singletons) can find them.
    const n = source.length;
    let residue: readonly Card[];
    if (ci === n - 1) {
      const r = planSplitAfter(sim, source, n - 1);
      out.push(...r.prims);
      sim = r.sim;
      residue = source.slice(0, n - 1);
    } else {
      const r = planSplitAfter(sim, source, 1);
      out.push(...r.prims);
      sim = r.sim;
      residue = source.slice(1);
    }
    const r = planSplitAfter(sim, residue, 1);
    out.push(...r.prims);
    sim = r.sim;
    extSingleton = [extCard];
  } else if (verb === "steal" && (kind === "pair_run" || kind === "pair_rb" || kind === "pair_set" || kind === "other")) {
    if (source.length !== 2) {
      throw new Error(`steal-from-partial expects length-2 source; got length ${source.length}`);
    }
    const r = planSplitAfter(sim, source, 1);
    out.push(...r.prims);
    sim = r.sim;
    extSingleton = [extCard];
  } else {
    throw new Error(`verb ${verb} kind ${kind} unsupported`);
  }

  // Merge the ext singleton onto target.
  const r = planMerge(sim, extSingleton, targetBefore, side, pendingHand);
  out.push(...r.prims);
  return out;
}

// --- free pull / push -------------------------------------------------

function freePullPrims(
  desc: FreePullDesc,
  board: readonly BoardStack[],
  pendingHand: ReadonlySet<string>,
): Primitive[] {
  const r = planMerge(board, [desc.loose], desc.targetBefore, desc.side, pendingHand);
  return r.prims;
}

function pushPrims(
  desc: PushDesc,
  board: readonly BoardStack[],
  pendingHand: ReadonlySet<string>,
): Primitive[] {
  const r = planMerge(board, desc.troubleBefore, desc.targetBefore, desc.side, pendingHand);
  return r.prims;
}

// --- splice -----------------------------------------------------------

function splicePrims(
  desc: SpliceDesc,
  board: readonly BoardStack[],
  pendingHand: ReadonlySet<string>,
): Primitive[] {
  const loose = desc.loose;
  const src = desc.source;
  const k = desc.k;
  const side = desc.side;

  let sim: readonly BoardStack[] = board;
  const a = planSplitAfter(sim, src, k);
  sim = a.sim;
  // side === "left"  : loose joins LEFT half  → src[:k] + [loose]
  // side === "right" : loose joins RIGHT half → [loose] + src[k:]
  const half = side === "left" ? src.slice(0, k) : src.slice(k);
  const mergeSide: Side = side === "left" ? "right" : "left";
  const b = planMerge(sim, [loose], half, mergeSide, pendingHand);
  return [...a.prims, ...b.prims];
}

// --- shift ------------------------------------------------------------

function shiftPrims(
  desc: ShiftDesc,
  board: readonly BoardStack[],
  pendingHand: ReadonlySet<string>,
): Primitive[] {
  const source = desc.source;
  const donor = desc.donor;
  const stolen = desc.stolen;
  const pCard = desc.pCard;
  const whichEnd = desc.whichEnd;
  const targetBefore = desc.targetBefore;
  const side = desc.side;

  let sim: readonly BoardStack[] = board;
  const out: Primitive[] = [];

  // 1. Isolate p_card from donor.
  const pi = indexOfCard(donor, pCard);
  const kind = classifyLeaf(donor);
  const iso = isolateCard(sim, donor, pi);
  out.push(...iso.prims);
  sim = iso.sim;
  if (kind === "set" && iso.remnants.length === 2) {
    const [leftChunk, tailChunk] = iso.remnants;
    const r = planMerge(sim, tailChunk!, leftChunk!, "right", pendingHand);
    out.push(...r.prims);
    sim = r.sim;
  }

  // 2. Merge p_card onto source on the OPPOSITE side from stolen.
  let augmentedSource: readonly Card[];
  let splitK: number;
  if (whichEnd === 0) {
    const r = planMerge(sim, [pCard], source, "right", pendingHand);
    out.push(...r.prims);
    sim = r.sim;
    augmentedSource = [...source, pCard];
    splitK = 1;
  } else {
    const r = planMerge(sim, [pCard], source, "left", pendingHand);
    out.push(...r.prims);
    sim = r.sim;
    augmentedSource = [pCard, ...source];
    splitK = source.length;
  }

  // 3. Pop stolen off the augmented source.
  const a = planSplitAfter(sim, augmentedSource, splitK);
  out.push(...a.prims);
  sim = a.sim;

  // 4. Merge stolen onto target.
  const m = planMerge(sim, [stolen], targetBefore, side, pendingHand);
  out.push(...m.prims);
  return out;
}

// --- decompose --------------------------------------------------------

function decomposePrims(
  desc: DecomposeDesc,
  board: readonly BoardStack[],
): Primitive[] {
  const r = planSplitAfter(board, desc.pairBefore, 1);
  return r.prims;
}
