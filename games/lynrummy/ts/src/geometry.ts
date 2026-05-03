// geometry.ts — TS port of python/geometry.py.
//
// Pure functions over a board-stacks-with-locations shape. No HTTP,
// no mutation. Used by the verb→primitive translator (verbs.ts) and
// the geometry post-pass (geometry_plan.ts) to keep the agent's
// emitted plays clear of the crowding/overlap thresholds the
// referee enforces (and stricter human-feel thresholds the agent
// enforces on its own).
//
// Constants must agree with `Game.Physics.BoardGeometry` (Elm) and
// the Go server's BoardBounds. Drift between layers is silent and
// load-bearing — when changing one, update all three.

import type { Card } from "./rules/card.ts";

// --- Stack shape with position ----------------------------------------

/** Board stack carrying a position. The BFS engine itself works on
 *  bare `Card[]`; this shape is used by the verb→primitive layer and
 *  any caller that has to reason about geometry. */
export interface BoardStack {
  readonly cards: readonly Card[];
  readonly loc: Loc;
}

export interface Loc {
  readonly top: number;
  readonly left: number;
}

export interface Rect {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

// --- Layout constants — match Elm + Go ---------------------------------

export const CARD_WIDTH = 27;
export const CARD_PITCH = CARD_WIDTH + 6;  // 33
export const CARD_HEIGHT = 40;

export const BOARD_MAX_WIDTH = 800;
export const BOARD_MAX_HEIGHT = 600;
export const BOARD_MARGIN = 7;

export const BOARD_VIEWPORT_LEFT = 300;
export const BOARD_VIEWPORT_TOP = 38;

export const PLACE_STEP = 10;

export const PACK_GAP_X = 30;
export const PACK_GAP_Y = 30;

export const ANTI_ALIGN_PX = 2;

/** Empty-board anchor: a little down-and-right from the top-left corner.
 *  Final placement is `(BOARD_START + ANTI_ALIGN_PX) = (26, 26)`. */
export const BOARD_START: Loc = { left: 24, top: 24 };

/** Preferred non-empty-board scan origin (Steve, 2026-04-23): humans
 *  don't land pre-moves near the (0,0) corner; they favor a left-biased
 *  zone with some inset on both axes. Toward-the-hand bias means
 *  preferring LOW x. (50, 90) is the lower-left edge of the observed
 *  human-placement cluster. */
export const HUMAN_PREFERRED_ORIGIN: Loc = { left: 50, top: 90 };

// --- Geometry primitives ----------------------------------------------

export function stackWidth(cardCount: number): number {
  if (cardCount <= 0) return 0;
  return CARD_WIDTH + (cardCount - 1) * CARD_PITCH;
}

export function stackRect(stack: BoardStack): Rect {
  const left = stack.loc.left;
  const top = stack.loc.top;
  return {
    left,
    top,
    right: left + stackWidth(stack.cards.length),
    bottom: top + CARD_HEIGHT,
  };
}

/** Axis-aligned overlap with exclusive edges. */
export function rectsOverlap(a: Rect, b: Rect): boolean {
  return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
}

export function padRect(r: Rect, margin: number): Rect {
  return {
    left: r.left - margin,
    top: r.top - margin,
    right: r.right + margin,
    bottom: r.bottom + margin,
  };
}

// --- Open-location finder ---------------------------------------------

/** Apply the fixed +2px anti-align nudge, clamped to bounds. */
function antiAlign(left: number, top: number, newW: number, newH: number): Loc {
  const jl = Math.min(left + ANTI_ALIGN_PX, BOARD_MAX_WIDTH - newW);
  const jt = Math.min(top + ANTI_ALIGN_PX, BOARD_MAX_HEIGHT - newH);
  return { left: jl, top: jt };
}

/**
 * Return a `Loc` for a new `cardCount`-card stack that doesn't overlap
 * any stack in `existing`.
 *
 * Scan is COLUMN-MAJOR (outer = left, inner = top), starting from
 * `HUMAN_PREFERRED_ORIGIN`. This embodies Steve's preference order:
 * left before right, then vertical (middle-ish) before advancing
 * further right. When the top rows are packed, the agent drops DOWN
 * in the same leftward column before shifting right — rightward is
 * the last option, not the first.
 *
 * The hand column sits off the board to the LEFT, so left-biased
 * placement also shortens the next hand-card drag.
 *
 * 100% deterministic. Same board state → same placement.
 */
export function findOpenLoc(
  existing: readonly BoardStack[],
  cardCount: number,
): Loc {
  const newW = stackWidth(cardCount);
  const newH = CARD_HEIGHT;
  const existingRects = existing.map(stackRect);

  // Empty board → fixed starting anchor.
  if (existingRects.length === 0) {
    return antiAlign(BOARD_START.left, BOARD_START.top, newW, newH);
  }

  // First-fit column-major scan at packing gap. Tighter step than the
  // legal-margin fallback so the 2px anti-align offset actually lands
  // off-grid.
  const step = 15;
  const minLeft = BOARD_MARGIN;
  const minTop = BOARD_MARGIN;
  const maxLeft = BOARD_MAX_WIDTH - newW - BOARD_MARGIN;
  const maxTop = BOARD_MAX_HEIGHT - newH - BOARD_MARGIN;

  // Clamp the preferred origin in case a future HUMAN_PREFERRED_ORIGIN
  // is too close to the right/bottom edge for the requested stack size.
  const startLeft = Math.min(Math.max(HUMAN_PREFERRED_ORIGIN.left, minLeft), maxLeft);
  const startTop = Math.min(Math.max(HUMAN_PREFERRED_ORIGIN.top, minTop), maxTop);

  const clears = (left: number, top: number): boolean => {
    const padded: Rect = {
      left: left - PACK_GAP_X,
      top: top - PACK_GAP_Y,
      right: left + newW + PACK_GAP_X,
      bottom: top + newH + PACK_GAP_Y,
    };
    for (const er of existingRects) if (rectsOverlap(padded, er)) return false;
    return true;
  };

  // Phase 1: scan from the preferred origin. Column-major so a packed
  // top row drops us downward in-place rather than pushing rightward.
  for (let left = startLeft; left <= maxLeft; left += step) {
    for (let top = startTop; top <= maxTop; top += step) {
      if (clears(left, top)) return antiAlign(left, top, newW, newH);
    }
  }

  // Phase 2: widen to the whole board, still column-major, before
  // falling through to the legal-margin crowded fallback.
  for (let left = minLeft; left <= maxLeft; left += step) {
    for (let top = minTop; top <= maxTop; top += step) {
      if (clears(left, top)) return antiAlign(left, top, newW, newH);
    }
  }

  // Board too crowded for the packing gap — drop to legal margin.
  return gridSweepOpenLoc(existingRects, newW, newH);
}

/** Deterministic row-major sweep at the legal (BOARD_MARGIN) padding.
 *  Fallback when packed-by-clearance can't satisfy the human-style
 *  spacing — the board is crowded enough that legal-minimum is the
 *  best we can do. */
function gridSweepOpenLoc(
  existingRects: readonly Rect[],
  newW: number,
  newH: number,
): Loc {
  for (let top = 0; top + newH <= BOARD_MAX_HEIGHT; top += PLACE_STEP) {
    for (let left = 0; left + newW <= BOARD_MAX_WIDTH; left += PLACE_STEP) {
      const candidate: Rect = {
        left: left - BOARD_MARGIN,
        top: top - BOARD_MARGIN,
        right: left + newW + BOARD_MARGIN,
        bottom: top + newH + BOARD_MARGIN,
      };
      let clears = true;
      for (const er of existingRects) {
        if (rectsOverlap(candidate, er)) { clears = false; break; }
      }
      if (clears) return { top, left };
    }
  }
  // Board fully crowded — fall back to bottom-left corner.
  const fallbackTop = Math.max(0, BOARD_MAX_HEIGHT - newH);
  return { top: fallbackTop, left: 0 };
}

// --- Bounds + violation checks ----------------------------------------

export function outOfBounds(stack: BoardStack): boolean {
  const r = stackRect(stack);
  return r.left < 0 || r.top < 0 || r.right > BOARD_MAX_WIDTH || r.bottom > BOARD_MAX_HEIGHT;
}

/** True iff a stack of `cardCount` cards anchored at `loc` fits in
 *  bounds and doesn't overlap (padded by BOARD_MARGIN) any stack in
 *  `board` except those whose indices are in `excludeIndices`.
 *  Mirrors the referee's two checks. */
export function locClearsOthers(
  loc: Loc,
  cardCount: number,
  board: readonly BoardStack[],
  excludeIndices: ReadonlySet<number> = new Set(),
): boolean {
  const rect: Rect = {
    left: loc.left,
    top: loc.top,
    right: loc.left + stackWidth(cardCount),
    bottom: loc.top + CARD_HEIGHT,
  };
  if (rect.left < 0 || rect.top < 0
      || rect.right > BOARD_MAX_WIDTH || rect.bottom > BOARD_MAX_HEIGHT) {
    return false;
  }
  const padded = padRect(rect, BOARD_MARGIN);
  for (let i = 0; i < board.length; i++) {
    if (excludeIndices.has(i)) continue;
    if (rectsOverlap(padded, stackRect(board[i]!))) return false;
  }
  return true;
}

/** Return the index of a stack that breaks the geometry rule, or null.
 *  Checks out-of-bounds first, then pairwise padded overlap.
 *
 *  Returns the FIRST offending stack rather than a full report —
 *  callers iterate: fix one, re-check, repeat until stable. When two
 *  stacks overlap, the LATER-indexed one is reported (it's the one
 *  that was appended most recently by a trick or by a growing
 *  neighbor; relocating it is less disruptive). */
export function findViolation(board: readonly BoardStack[]): number | null {
  for (let i = 0; i < board.length; i++) {
    if (outOfBounds(board[i]!)) return i;
  }
  const rects = board.map(stackRect);
  for (let i = 0; i < rects.length; i++) {
    const paddedI = padRect(rects[i]!, BOARD_MARGIN);
    for (let j = i + 1; j < rects.length; j++) {
      if (rectsOverlap(paddedI, rects[j]!)) return j;
    }
  }
  return null;
}
