// geometry_plan.ts — TS port of python/geometry_plan.py.
//
// Verbs (verbs.ts) emit a logical primitive sequence that's
// geometry-agnostic. `planActions` walks the sequence and injects
// pre-flight `move_stack` primitives anywhere a primitive would
// otherwise produce a board where two stacks are within PACK_GAP of
// each other.
//
// Agent invariant: after every primitive applies, no two stacks
// overlap (with PACK_GAP padding — the human-feel threshold,
// stricter than the referee's legal margin). A human player
// relocates crowded stacks BEFORE building on them; the agent matches
// by injecting MoveStacks at the points where the next primitive
// would otherwise produce a too-close result.
//
// Interior splits are pre-flighted unconditionally (Steve, 2026-04-23):
// even when the immediate post-board doesn't yet overlap, an interior
// split's siblings will sit in tight quarters that downstream
// primitives can't safely build on. Pre-moving the donor to a
// 4-side-clear region is the human-feel default.

import type { Card } from "./rules/card.ts";
import {
  type BoardStack, type Loc,
  CARD_PITCH, BOARD_MAX_WIDTH, BOARD_MAX_HEIGHT,
  stackRect, padRect, rectsOverlap, findOpenLoc,
} from "./geometry.ts";
import {
  type Primitive, type SplitPrim, type MergeStackPrim, type MoveStackPrim,
  applyLocally, cardsOf, findStackIndex,
} from "./primitives.ts";

export const PACK_GAP = 30;

/** Walk a primitive sequence; inject MoveStack pre-flights where the
 *  next primitive would land the post-board in a too-close state.
 *  Returns the augmented sequence. */
export function planActions(
  board: readonly BoardStack[],
  actions: readonly Primitive[],
): readonly Primitive[] {
  const out: Primitive[] = [];
  let sim: readonly BoardStack[] = board;
  for (const action of actions) {
    const { emitted, post } = planOne(sim, action);
    out.push(...emitted);
    sim = post;
  }
  return out;
}

function planOne(
  sim: readonly BoardStack[],
  action: Primitive,
): { emitted: Primitive[]; post: readonly BoardStack[] } {
  if (isInteriorSplit(sim, action)) {
    const pf = preFlight(sim, action);
    if (pf !== null) {
      return { emitted: [pf.move, pf.newAction], post: pf.newPost };
    }
  }
  const post = applyLocally(sim, action);
  if (isCleanAfterAction(sim, post)) {
    return { emitted: [action], post };
  }
  const pf = preFlight(sim, action);
  if (pf !== null) {
    return { emitted: [pf.move, pf.newAction], post: pf.newPost };
  }
  return { emitted: [action], post };
}

function isInteriorSplit(sim: readonly BoardStack[], action: Primitive): boolean {
  if (action.action !== "split") return false;
  const n = sim[action.stackIndex]!.cards.length;
  if (n < 3) return false;
  const ci = action.cardIndex;
  // Mirror applySplit's left_count derivation.
  const leftCount = ci + 1 <= Math.floor(n / 2) ? ci + 1 : ci;
  return leftCount !== 1 && leftCount !== n - 1;
}

interface PreFlightResult {
  readonly move: MoveStackPrim;
  readonly newAction: Primitive;
  readonly newPost: readonly BoardStack[];
}

function preFlight(sim: readonly BoardStack[], action: Primitive): PreFlightResult | null {
  if (action.action === "split") return preFlightSplit(sim, action);
  if (action.action === "merge_stack") return preFlightMergeStack(sim, action);
  return null;
}

function preFlightSplit(
  sim: readonly BoardStack[],
  action: SplitPrim,
): PreFlightResult | null {
  const si = action.stackIndex;
  const src = sim[si]!;
  const sourceSize = src.cards.length;
  const others = sim.filter((_, i) => i !== si);
  const newLoc = findOpenLoc(others, sourceSize);
  if (newLoc.top === src.loc.top && newLoc.left === src.loc.left) return null;
  const move: MoveStackPrim = {
    action: "move_stack", stackIndex: si, newLoc,
  };
  const afterMove = applyLocally(sim, move);
  const newSi = findStackIndex(afterMove, cardsOf(src));
  const newSplit: SplitPrim = {
    action: "split", stackIndex: newSi, cardIndex: action.cardIndex,
  };
  const afterSplit = applyLocally(afterMove, newSplit);
  return { move, newAction: newSplit, newPost: afterSplit };
}

function preFlightMergeStack(
  sim: readonly BoardStack[],
  action: MergeStackPrim,
): PreFlightResult | null {
  const srcSi = action.sourceStack;
  const tgtSi = action.targetStack;
  const src = sim[srcSi]!;
  const tgt = sim[tgtSi]!;
  const sourceSize = src.cards.length;
  const targetSize = tgt.cards.length;
  const finalSize = sourceSize + targetSize;
  const others = sim.filter((_, i) => i !== srcSi && i !== tgtSi);
  const finalLoc = findOpenLoc(others, finalSize);
  let targetLoc: Loc;
  if (action.side === "left") {
    targetLoc = {
      left: finalLoc.left + sourceSize * CARD_PITCH,
      top: finalLoc.top,
    };
  } else {
    targetLoc = finalLoc;
  }
  if (targetLoc.top === tgt.loc.top && targetLoc.left === tgt.loc.left) return null;
  const move: MoveStackPrim = {
    action: "move_stack", stackIndex: tgtSi, newLoc: targetLoc,
  };
  const afterMove = applyLocally(sim, move);
  const newSrcSi = findStackIndex(afterMove, cardsOf(src));
  const newTgtSi = findStackIndex(afterMove, cardsOf(tgt));
  const newMerge: MergeStackPrim = {
    action: "merge_stack",
    sourceStack: newSrcSi,
    targetStack: newTgtSi,
    side: action.side,
  };
  const afterMerge = applyLocally(afterMove, newMerge);
  return { move, newAction: newMerge, newPost: afterMerge };
}

/** Diff-based pack-gap check: new stacks (in post-board but not
 *  pre-board) must be pack-gap-clear from pre-existing stacks. New-
 *  vs-new pairs (split siblings) are exempt — they're inherently
 *  close by the +8px split offset, but that's not a primitive emitting
 *  an overlap with the rest of the board.
 *
 *  Out-of-bounds check applies to all stacks unconditionally. */
function isCleanAfterAction(
  preBoard: readonly BoardStack[],
  postBoard: readonly BoardStack[],
): boolean {
  const preKeys = new Set(preBoard.map(stackKey));
  const preExisting: BoardStack[] = [];
  const newStacks: BoardStack[] = [];
  for (const s of postBoard) {
    if (preKeys.has(stackKey(s))) preExisting.push(s);
    else newStacks.push(s);
  }

  for (const s of postBoard) {
    const r = stackRect(s);
    if (r.left < 0 || r.top < 0
        || r.right > BOARD_MAX_WIDTH || r.bottom > BOARD_MAX_HEIGHT) {
      return false;
    }
  }

  for (const fresh of newStacks) {
    const newPadded = padRect(stackRect(fresh), PACK_GAP);
    for (const old of preExisting) {
      if (rectsOverlap(newPadded, stackRect(old))) return false;
    }
  }
  return true;
}

/** Identity for diffing pre/post boards: content + loc. A stack that
 *  moves reads as "new" and the original as "removed." */
function stackKey(s: BoardStack): string {
  const cards = s.cards.map(c => `${c[0]},${c[1]},${c[2]}`).join(";");
  return `${s.loc.top},${s.loc.left}|${cards}`;
}
