// physical_plan.ts — single global pass that turns (initialBoard,
// placements, planDescs) into a physical primitive sequence.
//
// Two stages, ONE pass at the function-call level:
//
//   1. Logical trace — emit the same place_hand+merge_hand seed for
//      placements that the legacy `playToPrimitives` did, then expand
//      each plan-desc through the pure `expandVerb`. Geometry-agnostic.
//
//   2. Singleton hand-card lift (v1) — when a single placement is
//      consumed downstream by a merge_stack with the placement-singleton
//      as source OR target, drop the place_hand and rewrite the consumer
//      as a direct merge_hand. Pull/push semantic flips: a merge_stack
//      where the placement is the TARGET (something else absorbs into
//      P) lifts to merge_hand(P → other-stack, flipSide(side)) — same
//      physical motion, dragged-piece-active grammar.
//
//   3. Global geometry — single `planActions` pass over the lifted
//      sequence injects pre-flight move_stack primitives with
//      whole-program visibility.
//
// Per Steve, 2026-05-04: there should be ONE solver pass and ONE
// physical-execution pass. Per-verb pre-flighting (the legacy path
// in `moveToPrimitives`) is the "intermediate pass too dumb to have
// value." `physicalPlan` replaces that intermediate.
//
// v1 scope: SINGLE-placement turns get the lift. Multi-placement turns
// fall through unchanged (place_hand seed + merge_hand growing-stack +
// downstream verbs as before). Easy multi-placement wins (pair stays
// together → both cards play directly to the eventual destination)
// remain open work.

import type { Card } from "./rules/card.ts";
import type { Desc } from "./move.ts";
import type { BoardStack, Loc } from "./geometry.ts";
import { findOpenLoc } from "./geometry.ts";
import {
  type Primitive, type Side,
  applyLocally, findStackIndex,
} from "./primitives.ts";
import { expandVerb } from "./verbs.ts";
import { planActions } from "./geometry_plan.ts";

function flipSide(s: Side): Side {
  return s === "left" ? "right" : "left";
}

function cardEq(a: Card, b: Card): boolean {
  return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
}

function cardsEq(a: readonly Card[], b: readonly Card[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (!cardEq(a[i]!, b[i]!)) return false;
  return true;
}

/** Single global pass: logical → lift → geometry. Returns the final
 *  primitive sequence ready for the wire. */
export function physicalPlan(
  initialBoard: readonly BoardStack[],
  placements: readonly Card[],
  planDescs: readonly Desc[],
): readonly Primitive[] {
  const logical = emitLogicalTrace(initialBoard, placements, planDescs);
  const lifted = placements.length === 1
    ? (liftSinglePlacement(initialBoard, placements[0]!, logical) ?? logical)
    : logical;
  return planActions(initialBoard, lifted);
}

/** Step A: emit the same primitives the legacy playToPrimitives used
 *  to. Multi-placement turns get the place_hand+merge_hand growing-stack
 *  seed; single-placement turns get one place_hand. Then each plan-desc
 *  expands through `expandVerb` against the running sim. */
function emitLogicalTrace(
  initialBoard: readonly BoardStack[],
  placements: readonly Card[],
  planDescs: readonly Desc[],
): readonly Primitive[] {
  const out: Primitive[] = [];
  let sim: readonly BoardStack[] = initialBoard;

  if (placements.length > 0) {
    // Reserve loc for the EVENTUAL stack width (matches the legacy
    // playToPrimitives reservation). For single-placement turns the
    // place_hand will be dropped by the lift in most cases, so this
    // loc is only consequential for the multi-placement case.
    const placeLoc = findOpenLoc(sim, placements.length);
    const place: Primitive = {
      action: "place_hand", handCard: placements[0]!, loc: placeLoc,
    };
    out.push(place);
    sim = applyLocally(sim, place);
    for (let i = 1; i < placements.length; i++) {
      const lastIdx = sim.length - 1;
      const merge: Primitive = {
        action: "merge_hand",
        targetStack: lastIdx,
        handCard: placements[i]!,
        side: "right",
      };
      out.push(merge);
      sim = applyLocally(sim, merge);
    }
  }

  for (const desc of planDescs) {
    const prims = expandVerb(desc, sim);
    for (const p of prims) {
      out.push(p);
      sim = applyLocally(sim, p);
    }
  }

  return out;
}

/** Step B: try to lift a single placement P. Returns the rewritten
 *  primitive list, or null if the placement isn't cleanly liftable
 *  (then the caller falls back to the un-lifted logical trace).
 *
 *  Liftability: there's a place_hand(P) followed by a merge_stack whose
 *  source OR target is the [P] singleton, AND nothing in between
 *  references the [P] singleton. In that case we drop the place_hand
 *  and rewrite the merge_stack as merge_hand. */
function liftSinglePlacement(
  initialBoard: readonly BoardStack[],
  placement: Card,
  prims: readonly Primitive[],
): readonly Primitive[] | null {
  // Capture the content each primitive operates on, computed against
  // the ORIGINAL sim (with the placement applied). We re-resolve indices
  // against a new sim during re-emission.
  type Content =
    | { kind: "split"; stack: readonly Card[]; ci: number }
    | { kind: "merge_stack"; src: readonly Card[]; tgt: readonly Card[]; side: Side }
    | { kind: "merge_hand"; tgt: readonly Card[]; handCard: Card; side: Side }
    | { kind: "move_stack"; stack: readonly Card[]; newLoc: Loc }
    | { kind: "place_hand"; handCard: Card; loc: Loc };

  const contents: Content[] = [];
  let origSim: readonly BoardStack[] = initialBoard;
  for (const p of prims) {
    switch (p.action) {
      case "split":
        contents.push({
          kind: "split",
          stack: origSim[p.stackIndex]!.cards,
          ci: p.cardIndex,
        });
        break;
      case "merge_stack":
        contents.push({
          kind: "merge_stack",
          src: origSim[p.sourceStack]!.cards,
          tgt: origSim[p.targetStack]!.cards,
          side: p.side,
        });
        break;
      case "merge_hand":
        contents.push({
          kind: "merge_hand",
          tgt: origSim[p.targetStack]!.cards,
          handCard: p.handCard,
          side: p.side,
        });
        break;
      case "move_stack":
        contents.push({
          kind: "move_stack",
          stack: origSim[p.stackIndex]!.cards,
          newLoc: p.newLoc,
        });
        break;
      case "place_hand":
        contents.push({ kind: "place_hand", handCard: p.handCard, loc: p.loc });
        break;
    }
    origSim = applyLocally(origSim, p);
  }

  // Find place_hand of P.
  const placeIdx = prims.findIndex(
    p => p.action === "place_hand" && cardEq(p.handCard, placement),
  );
  if (placeIdx === -1) return null;

  // Find first consumer of [P] singleton. Reject if anything else
  // references [P] before then.
  let consumeIdx = -1;
  let consumerKind: "src" | "tgt" | null = null;
  for (let j = placeIdx + 1; j < prims.length; j++) {
    const c = contents[j]!;
    if (c.kind === "split" && cardsEq(c.stack, [placement])) return null;
    if (c.kind === "move_stack" && cardsEq(c.stack, [placement])) return null;
    if (c.kind === "merge_hand" && cardsEq(c.tgt, [placement])) return null;
    if (c.kind === "merge_hand" && cardEq(c.handCard, placement)) return null;
    if (c.kind === "merge_stack") {
      if (cardsEq(c.src, [placement])) {
        consumeIdx = j; consumerKind = "src"; break;
      }
      if (cardsEq(c.tgt, [placement])) {
        consumeIdx = j; consumerKind = "tgt"; break;
      }
    }
  }
  if (consumeIdx === -1) return null;

  // Re-emit. Walk the original primitives, drop the place_hand, replace
  // the consumer merge_stack with merge_hand, and re-resolve every
  // intermediate primitive's indices against the new sim.
  let sim: readonly BoardStack[] = initialBoard;
  const out: Primitive[] = [];
  for (let i = 0; i < prims.length; i++) {
    if (i === placeIdx) continue;
    const c = contents[i]!;
    if (i === consumeIdx) {
      const m = c as Extract<Content, { kind: "merge_stack" }>;
      let liftedPrim: Primitive;
      if (consumerKind === "src") {
        // P was the source being absorbed INTO m.tgt. Direct-drag is
        // merge_hand(P → tgt, side) — same side as the original
        // merge_stack.
        const tgtIdx = findStackIndex(sim, m.tgt);
        liftedPrim = {
          action: "merge_hand", targetStack: tgtIdx,
          handCard: placement, side: m.side,
        };
      } else {
        // P was the target — m.src absorbed INTO [P]. Direct-drag is
        // merge_hand(P → src, flipSide(side)) — gesture grammar
        // mirrors absorber-active framing, side flips so the final
        // card order matches.
        const srcIdx = findStackIndex(sim, m.src);
        liftedPrim = {
          action: "merge_hand", targetStack: srcIdx,
          handCard: placement, side: flipSide(m.side),
        };
      }
      out.push(liftedPrim);
      sim = applyLocally(sim, liftedPrim);
      continue;
    }
    let newPrim: Primitive;
    switch (c.kind) {
      case "split": {
        const idx = findStackIndex(sim, c.stack);
        newPrim = { action: "split", stackIndex: idx, cardIndex: c.ci };
        break;
      }
      case "merge_stack": {
        const srcIdx = findStackIndex(sim, c.src);
        const tgtIdx = findStackIndex(sim, c.tgt);
        newPrim = {
          action: "merge_stack",
          sourceStack: srcIdx, targetStack: tgtIdx, side: c.side,
        };
        break;
      }
      case "merge_hand": {
        const tgtIdx = findStackIndex(sim, c.tgt);
        newPrim = {
          action: "merge_hand",
          targetStack: tgtIdx, handCard: c.handCard, side: c.side,
        };
        break;
      }
      case "move_stack": {
        const idx = findStackIndex(sim, c.stack);
        newPrim = { action: "move_stack", stackIndex: idx, newLoc: c.newLoc };
        break;
      }
      case "place_hand":
        newPrim = { action: "place_hand", handCard: c.handCard, loc: c.loc };
        break;
    }
    out.push(newPrim);
    sim = applyLocally(sim, newPrim);
  }
  return out;
}
