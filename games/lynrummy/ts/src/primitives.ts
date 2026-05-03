// primitives.ts — TS port of python/primitives.py + the relevant
// apply_* helpers from python/strategy.py.
//
// Primitives are the atomic UI ops the agent emits: split / merge_stack
// / merge_hand / move_stack / place_hand. The verb→primitive translator
// (verbs.ts) emits a deterministic primitive sequence per high-level
// verb; the geometry post-pass (geometry_plan.ts) injects pre-flight
// move_stack primitives where crowding would otherwise occur.
//
// `applyLocally` mirrors what the server does on receipt — lets
// downstream callers (verbs.ts, geometry_plan.ts, the trace harness)
// thread a simulated board through a primitive sequence without round-
// tripping through HTTP. Per Steve, 2026-05-03: the agent uses the file
// system going forward, no HTTP. So we skip Python's `to_wire_shape` /
// `send_one`.

import type { Card } from "./rules/card.ts";
import { CARD_PITCH, type BoardStack, type Loc } from "./geometry.ts";

// --- Primitive descriptors --------------------------------------------

export type Side = "left" | "right";

export interface SplitPrim {
  readonly action: "split";
  readonly stackIndex: number;
  readonly cardIndex: number;
}

export interface MergeStackPrim {
  readonly action: "merge_stack";
  readonly sourceStack: number;
  readonly targetStack: number;
  readonly side: Side;
}

export interface MergeHandPrim {
  readonly action: "merge_hand";
  readonly targetStack: number;
  readonly handCard: Card;
  readonly side: Side;
}

export interface MoveStackPrim {
  readonly action: "move_stack";
  readonly stackIndex: number;
  readonly newLoc: Loc;
}

export interface PlaceHandPrim {
  readonly action: "place_hand";
  readonly handCard: Card;
  readonly loc: Loc;
}

export type Primitive =
  | SplitPrim
  | MergeStackPrim
  | MergeHandPrim
  | MoveStackPrim
  | PlaceHandPrim;

// --- Local apply (mirrors server-side state evolution) ----------------

/** Apply a split: the source stack at index `si` is replaced by two
 *  halves (left = cards[..ci+1], right = cards[ci+1..]). Locations
 *  follow Go CardStack.Split: half-asymmetric nudges based on whether
 *  the split point is in the first or second half. */
function applySplit(board: readonly BoardStack[], si: number, ci: number): BoardStack[] {
  const stack = board[si]!;
  const size = stack.cards.length;
  const srcLeft = stack.loc.left;
  const srcTop = stack.loc.top;
  let leftCount: number;
  let leftLoc: Loc;
  let rightLoc: Loc;
  if (ci + 1 <= Math.floor(size / 2)) {
    // leftSplit: left stays high/left, right hops right + 8.
    leftCount = ci + 1;
    leftLoc = { top: srcTop - 4, left: srcLeft - 2 };
    rightLoc = { top: srcTop, left: srcLeft + leftCount * CARD_PITCH + 8 };
  } else {
    // rightSplit: left nudges left -8, right hops right + 4.
    leftCount = ci;
    leftLoc = { top: srcTop, left: srcLeft - 8 };
    rightLoc = { top: srcTop - 4, left: srcLeft + leftCount * CARD_PITCH + 4 };
  }
  const left: BoardStack = {
    cards: stack.cards.slice(0, leftCount),
    loc: leftLoc,
  };
  const right: BoardStack = {
    cards: stack.cards.slice(leftCount),
    loc: rightLoc,
  };
  return [...board.slice(0, si), ...board.slice(si + 1), left, right];
}

function applyMove(board: readonly BoardStack[], si: number, newLoc: Loc): BoardStack[] {
  const s = board[si]!;
  const moved: BoardStack = { cards: s.cards, loc: { ...newLoc } };
  return [...board.slice(0, si), ...board.slice(si + 1), moved];
}

function applyMergeStack(
  board: readonly BoardStack[],
  src: number,
  tgt: number,
  side: Side,
): BoardStack[] {
  const s = board[src]!;
  const t = board[tgt]!;
  let newCards: readonly Card[];
  let loc: Loc;
  if (side === "left") {
    newCards = [...s.cards, ...t.cards];
    // Go's LeftMerge: merged stack's left edge shifts left by the
    // width of the incoming cards.
    loc = { left: t.loc.left - CARD_PITCH * s.cards.length, top: t.loc.top };
  } else {
    newCards = [...t.cards, ...s.cards];
    loc = { ...t.loc };
  }
  const merged: BoardStack = { cards: newCards, loc };
  const [hi, lo] = src > tgt ? [src, tgt] : [tgt, src];
  const out = [...board];
  out.splice(hi, 1);
  out.splice(lo, 1);
  return [...out, merged];
}

function applyMergeHand(
  board: readonly BoardStack[],
  targetIdx: number,
  handCard: Card,
  side: Side,
): BoardStack[] {
  const t = board[targetIdx]!;
  let newCards: readonly Card[];
  let loc: Loc;
  if (side === "left") {
    newCards = [handCard, ...t.cards];
    loc = { left: t.loc.left - CARD_PITCH, top: t.loc.top };
  } else {
    newCards = [...t.cards, handCard];
    loc = { ...t.loc };
  }
  const merged: BoardStack = { cards: newCards, loc };
  return [...board.slice(0, targetIdx), ...board.slice(targetIdx + 1), merged];
}

function applyPlaceHand(
  board: readonly BoardStack[],
  handCard: Card,
  loc: Loc,
): BoardStack[] {
  return [...board, { cards: [handCard], loc: { ...loc } }];
}

/** Mirror of what the server does on receipt of one primitive. Pure
 *  function on the board state; safe to thread sequentially through
 *  a primitive list. */
export function applyLocally(
  board: readonly BoardStack[],
  prim: Primitive,
): readonly BoardStack[] {
  switch (prim.action) {
    case "split":
      return applySplit(board, prim.stackIndex, prim.cardIndex);
    case "move_stack":
      return applyMove(board, prim.stackIndex, prim.newLoc);
    case "merge_stack":
      return applyMergeStack(board, prim.sourceStack, prim.targetStack, prim.side);
    case "merge_hand":
      return applyMergeHand(board, prim.targetStack, prim.handCard, prim.side);
    case "place_hand":
      return applyPlaceHand(board, prim.handCard, prim.loc);
  }
}

// --- Content-by-tuple lookup (verbs.ts uses this to resolve
//     stack indices after each primitive applies) -------------------

export function cardsOf(stack: BoardStack): readonly Card[] {
  return stack.cards;
}

function cardEq(a: Card, b: Card): boolean {
  return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
}

function cardsEq(a: readonly Card[], b: readonly Card[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (!cardEq(a[i]!, b[i]!)) return false;
  return true;
}

/** Index of the stack on `board` whose content matches `cards` exactly.
 *  Throws if absent. Mirrors Python's `find_stack_index`. */
export function findStackIndex(
  board: readonly BoardStack[],
  cards: readonly Card[],
): number {
  for (let i = 0; i < board.length; i++) {
    if (cardsEq(board[i]!.cards, cards)) return i;
  }
  throw new Error(`stack not found on board: [${cards.map(c => `${c[0]},${c[1]},${c[2]}`).join(" ")}]`);
}
