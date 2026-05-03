// verbs.ts — TS port of python/verbs.py.
//
// Pipeline: VERBs (BFS descs) → PRIMITIVEs (UI atomic ops) →
// (eventually) GESTUREs.
//
// `moveToPrimitives(desc, board)` decomposes one BFS verb into a
// deterministic sequence of UI primitives. Stacks are identified by
// content (Card[]) at each step rather than by symbolic indices:
// after each primitive applies locally, the next primitive looks up
// its inputs by content match. This avoids the index-shuffle
// bookkeeping that the server's split/merge semantics impose.
//
// The per-verb helpers below emit a geometry-agnostic primitive
// sequence; the final `geometry_plan.planActions` pass injects
// pre-flight `move_stack` primitives wherever the next primitive
// would land the board too close to a pre-existing stack (or
// off-board). Pre-flight planning, never post-hoc tidy.

import type { Card } from "./rules/card.ts";
import type {
  Desc, Side,
  ExtractAbsorbDesc, FreePullDesc, PushDesc,
  ShiftDesc, SpliceDesc, DecomposeDesc,
} from "./move.ts";
import type { BoardStack } from "./geometry.ts";
import {
  type Primitive, type SplitPrim, type MergeStackPrim,
  applyLocally, findStackIndex,
} from "./primitives.ts";
import { planActions } from "./geometry_plan.ts";
import { classifyStack } from "./classified_card_stack.ts";

/** Decompose one BFS verb into UI primitives, then run the geometry
 *  post-pass. Returns the augmented (possibly-pre-flighted) sequence. */
export function moveToPrimitives(
  desc: Desc,
  board: readonly BoardStack[],
): readonly Primitive[] {
  let raw: Primitive[];
  switch (desc.type) {
    case "extract_absorb": raw = extractAbsorbPrims(desc, board); break;
    case "free_pull":      raw = freePullPrims(desc, board); break;
    case "push":           raw = pushPrims(desc, board); break;
    case "splice":         raw = splicePrims(desc, board); break;
    case "shift":          raw = shiftPrims(desc, board); break;
    case "decompose":      raw = decomposePrims(desc, board); break;
  }
  return planActions(board, raw);
}

// --- helpers --------------------------------------------------

/** Plan a split that puts the first `k` cards of `stackContent` into
 *  the left half and the rest into the right half. Geometry-agnostic;
 *  any necessary pre-flight is added by `planActions`.
 *  Returns (prims, newSim). */
function planSplitAfter(
  sim: readonly BoardStack[],
  stackContent: readonly Card[],
  k: number,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const n = stackContent.length;
  if (!(k >= 1 && k <= n - 1)) {
    throw new Error(`split-after k=${k} out of range for n=${n}`);
  }
  // Mirror applySplit's left_count derivation: ci=k-1 if k <= n/2,
  // else ci=k.
  const ci = k <= Math.floor(n / 2) ? k - 1 : k;
  const si = findStackIndex(sim, stackContent);
  const split: SplitPrim = {
    action: "split", stackIndex: si, cardIndex: ci,
  };
  return { prims: [split], sim: applyLocally(sim, split) };
}

/** Plan a content-addressed merge_stack. Geometry-agnostic. */
function planMerge(
  sim: readonly BoardStack[],
  sourceContent: readonly Card[],
  targetContent: readonly Card[],
  side: Side,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  const src = findStackIndex(sim, sourceContent);
  const tgt = findStackIndex(sim, targetContent);
  const merge: MergeStackPrim = {
    action: "merge_stack",
    sourceStack: src, targetStack: tgt, side,
  };
  return { prims: [merge], sim: applyLocally(sim, merge) };
}

/** Translate Python rules-classify kinds to TS leaf kinds. */
type LeafKind = "set" | "pure_run" | "rb_run" | "other";
function classifyLeaf(cards: readonly Card[]): LeafKind {
  const ccs = classifyStack(cards);
  if (ccs === null || ccs.n < 3) return "other";
  if (ccs.kind === "set") return "set";
  if (ccs.kind === "run") return "pure_run";
  if (ccs.kind === "rb") return "rb_run";
  return "other";
}

// --- extract + absorb ----------------------------------------

/** Generate the split primitives needed to leave the card at index
 *  `ci` of `stackContent` as a singleton on `sim`. Returns prims, new
 *  sim, the ext singleton card, and the remnant stacks left on the
 *  board (1 piece for end-extraction; 2 pieces for interior). */
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
  const a = planSplitAfter(sim, stackContent, ci);
  out.push(...a.prims);
  const rightChunk = stackContent.slice(ci);
  const b = planSplitAfter(a.sim, rightChunk, 1);
  out.push(...b.prims);
  return {
    prims: out, sim: b.sim, extSingleton: [extCard],
    remnants: [stackContent.slice(0, ci), stackContent.slice(ci + 1)],
  };
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

  if (verb === "peel" || verb === "pluck" || verb === "yank" || verb === "split_out") {
    // Same physical isolation regardless of verb. The peel/pluck/
    // yank/split_out distinction is which spawned pieces qualify as
    // helpers vs trouble — a logical-layer concern; physically all
    // are split-then-merge.
    const iso = isolateCard(sim, source, ci);
    out.push(...iso.prims);
    sim = iso.sim;
    extSingleton = iso.extSingleton;

    // Set peel from interior position: physically the remnant is
    // split into TWO pieces (left chunk + tail chunk). The BFS
    // solver treats the remnant as a single legal set [a, b, d]; we
    // need to merge the two physical pieces back together.
    if (kind === "set" && iso.remnants.length === 2) {
      const [leftChunk, tailChunk] = iso.remnants;
      const r = planMerge(sim, tailChunk!, leftChunk!, "right");
      out.push(...r.prims);
      sim = r.sim;
    }
  } else if (verb === "steal" && (kind === "pure_run" || kind === "rb_run")) {
    // End-steal of length-3 run: ci is 0 or 2.
    const iso = isolateCard(sim, source, ci);
    out.push(...iso.prims);
    sim = iso.sim;
    extSingleton = iso.extSingleton;
  } else if (verb === "steal" && kind === "set") {
    // Detach extCard FIRST (split at the end where it sits) so the
    // user sees the steal as the visible action; then dismantle the
    // remaining same-value pair into two singletons.
    const n = source.length;
    let residue: readonly Card[];
    if (ci === n - 1) {
      // X at right end: split @(n-1) → [pair] + [X].
      const r = planSplitAfter(sim, source, n - 1);
      out.push(...r.prims);
      sim = r.sim;
      residue = source.slice(0, n - 1);
    } else {
      // ci === 0 (left end) or ci === 1 (interior — rare). Split @1.
      const r = planSplitAfter(sim, source, 1);
      out.push(...r.prims);
      sim = r.sim;
      residue = source.slice(1);
    }
    // Dismantle the same-value remnant pair so subsequent BFS-
    // planned moves (push spawned singletons) can find them.
    const r = planSplitAfter(sim, residue, 1);
    out.push(...r.prims);
    sim = r.sim;
    extSingleton = [extCard];
  } else if (verb === "steal" && (kind === "pair_run" || kind === "pair_rb" || kind === "pair_set" || kind === "other")) {
    // Steal-from-partial (length-2 source). canSteal was extended
    // 2026-05-02 to allow length-2 sources; physically a single
    // split at k=1 separates the two cards. The "pair_*" / "other"
    // arms are reached when source.length === 2.
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

  // Merge ext_card singleton onto target.
  const r = planMerge(sim, extSingleton, targetBefore, side);
  out.push(...r.prims);
  return out;
}

// --- free pull / push ----------------------------------------

function freePullPrims(
  desc: FreePullDesc,
  board: readonly BoardStack[],
): Primitive[] {
  // A loose TROUBLE singleton is already on the board; merge it onto
  // the target.
  const r = planMerge(board, [desc.loose], desc.targetBefore, desc.side);
  return r.prims;
}

function pushPrims(
  desc: PushDesc,
  board: readonly BoardStack[],
): Primitive[] {
  // Push a TROUBLE singleton or 2-partial onto a HELPER stack. The
  // trouble cards are already on the board as a single stack.
  const r = planMerge(board, desc.troubleBefore, desc.targetBefore, desc.side);
  return r.prims;
}

// --- splice --------------------------------------------------

function splicePrims(
  desc: SpliceDesc,
  board: readonly BoardStack[],
): Primitive[] {
  // Insert a TROUBLE singleton into a HELPER pure/rb run. Split the
  // run at k, then merge the loose onto the half it joins (per side).
  // The other half persists untouched.
  const loose = desc.loose;
  const src = desc.source;
  const k = desc.k;
  const side = desc.side;

  let sim: readonly BoardStack[] = board;
  const a = planSplitAfter(sim, src, k);
  sim = a.sim;
  // side === "left"  : loose joins LEFT half  → src[:k] + [loose]
  // side === "right" : loose joins RIGHT half → [loose] + src[k:]
  const b = side === "left"
    ? planMerge(sim, [loose], src.slice(0, k), "right")
    : planMerge(sim, [loose], src.slice(k), "left");
  return [...a.prims, ...b.prims];
}

// --- shift ---------------------------------------------------

function shiftPrims(
  desc: ShiftDesc,
  board: readonly BoardStack[],
): Primitive[] {
  // Shift verb: p_card moves from donor INTO source's opposite-end
  // position, displacing stolen, which then absorbs onto target.
  //
  // Sequence (the user sees the LOGIC of the swap):
  //   1. Isolate p_card from donor (split, plus interior-set
  //      reassemble if applicable).
  //   2. Merge p_card onto source on the OPPOSITE side from stolen.
  //      Source becomes augmented (length+1).
  //   3. Pop stolen off the augmented source by splitting at its end.
  //   4. Merge stolen onto target.
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
    const r = planMerge(sim, tailChunk!, leftChunk!, "right");
    out.push(...r.prims);
    sim = r.sim;
  }

  // 2. Merge p_card onto source. p_card joins the OPPOSITE side from
  // stolen, so that splitting at the stolen end next yields the
  // correct new_source.
  let augmentedSource: readonly Card[];
  let splitK: number;
  if (whichEnd === 0) {
    // stolen at LEFT of source; p_card joins RIGHT.
    const r = planMerge(sim, [pCard], source, "right");
    out.push(...r.prims);
    sim = r.sim;
    augmentedSource = [...source, pCard];
    splitK = 1;
  } else {
    // stolen at RIGHT of source; p_card joins LEFT.
    const r = planMerge(sim, [pCard], source, "left");
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
  const m = planMerge(sim, [stolen], targetBefore, side);
  out.push(...m.prims);
  return out;
}

// --- decompose ----------------------------------------------

/** Decompose a 2-card pair stack into two singletons. Physically:
 *  one split at k=1. Per Steve, 2026-05-03: emit a real split so UI
 *  state stays consistent with BFS state — the user sees a discrete
 *  click that separates the pair. */
function decomposePrims(
  desc: DecomposeDesc,
  board: readonly BoardStack[],
): Primitive[] {
  const r = planSplitAfter(board, desc.pairBefore, 1);
  return r.prims;
}
