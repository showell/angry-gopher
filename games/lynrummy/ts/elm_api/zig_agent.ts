// zig_agent.ts — Player Two's boundary with the zig solver
// (solver.wasm `agentStep`). The zig side PICKS the play — the sim
// policy: smallest hand subset that plays, most kept player edges
// within that size — and answers with its build recipe, one
// moves.zig formatMove line per step:
//
//   place C [onto [DST] -> [RES]] [to build an eventual run [GOAL]]
//   push C onto [DST] -> [RES]
//   peel C from [SRC] [onto [DST] -> [RES]]
//   steal C from [SRC] [onto [DST] -> [RES]]
//   split [SRC] -> [LEFT] + [RIGHT]
//   merge [SRC] onto [DST] -> [RES]
//
// This module owns both directions of that wire: lowering the Elm
// board/hand DSL to the solver's ASCII arrangement input, and lifting
// the recipe back into the geometry primitives Elm animates.
// Choreography stays TS — the verbs.ts helpers (isolate, planMerge,
// planSplitAfter) do all the physical thinking: locs, paths, crowding
// pre-flights, hand-direct merges, small-onto-large flips.
//
// The recipe is a faithful build script (the zig distiller simulates
// it and fails loud on mismatch), so the lift walks it move by move
// against a simulated board, addressing stacks by exact content —
// a stale reference throws rather than drifting.

import { type Card, RANKS, SUITS, Deck, parseCardLabel } from "../core/card.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { findOpenLoc } from "../geometry/geometry.ts";
import {
  type Primitive,
  applyLocally, makePlaceHand,
} from "../game_events/primitives.ts";
import { parseBoardDsl, parseCardList } from "../dsl/parse.ts";
import { formatPrimitive } from "../dsl/emit.ts";
import { isolateCard, planMerge, planSplitAfter } from "../plan/verbs.ts";
import { cardKey } from "../plan/board.ts";

/** The solver speaks ASCII ("TC'"), the DSL speaks glyphs ("T♣'"). */
function asciiToken(c: Card): string {
  return RANKS[c.rank - 1]! + SUITS[c.suit]! + (c.deck === Deck.One ? "" : "'");
}

/** Lower Elm's board + hand DSL to the wasm agentStep input: the
 *  arrangement line ("3H>4S>5H KH=KC=KS QD"), a newline, the hand
 *  tokens. Same lowering the glue does for game_hint, board-DSL-in
 *  instead of wire-objects-in. */
export function zigAgentInput(boardDsl: string, handDsl: string): string {
  const line = parseBoardDsl(boardDsl).map(s =>
    s.cards.map((c, i) => {
      const link = i === 0 ? "" : s.cards[i - 1]!.rank === c.rank ? "=" : ">";
      return link + asciiToken(c);
    }).join(""),
  ).join(" ");
  const hand = parseCardList(handDsl).map(asciiToken).join(" ");
  return line + "\n" + hand;
}

/** Lift one zig build recipe into the primitives DSL Elm animates.
 *  `boardDsl`/`handDsl` are the same strings the recipe was computed
 *  from. Returns newline-joined primitive lines. Throws on any recipe
 *  line it cannot realize — a boundary bug must fail loud, never play
 *  a wrong move. */
export function zigPlanPrimitives(
  boardDsl: string,
  handDsl: string,
  planText: string,
): string {
  const board = parseBoardDsl(boardDsl);
  const prims = liftPlan(board, parseCardList(handDsl), planText);
  // Render against the original board, replaying the same evolution.
  let fmt: readonly BoardStack[] = board;
  const lines = prims.map(p => {
    const s = formatPrimitive(p, fmt);
    fmt = applyLocally(fmt, p);
    return s;
  });
  return lines.join("\n");
}

/** The primitive-level workhorse behind `zigPlanPrimitives`; the
 *  conformance runner drives it directly so its invariants can apply
 *  the primitives without a parse-back. */
export function liftPlan(
  board: readonly BoardStack[],
  hand: readonly Card[],
  planText: string,
): Primitive[] {
  const pendingHand = new Set(hand.map(cardKey));
  let sim: readonly BoardStack[] = board;
  const out: Primitive[] = [];

  const push = (prims: readonly Primitive[], after: readonly BoardStack[]) => {
    for (const p of prims) {
      out.push(p);
      if (p.action === "merge_hand" || p.action === "place_hand") {
        pendingHand.delete(cardKey(p.handCard));
      }
    }
    sim = after;
  };

  for (const rawLine of planText.split("\n")) {
    const line = rawLine.trim();
    if (line === "") continue;
    const m = parsePlanLine(line);
    switch (m.verb) {
      case "split": {
        const r = planSplitAfter(sim, m.groups[0]!, m.groups[1]!.length);
        push(r.prims, r.sim);
        break;
      }
      case "merge": {
        const [src, dst, res] = m.groups;
        const r = planMerge(sim, src!, dst!, sideOf(res!, src![0]!), pendingHand);
        push(r.prims, r.sim);
        break;
      }
      case "peel":
      case "steal": {
        const src = m.groups[0]!;
        const iso = isolateCard(sim, src, indexOfCard(src, m.card!));
        push(iso.prims, iso.sim);
        if (iso.remnants.length === 2) {
          // The zig board model closes the gap (a mid-set steal
          // leaves ONE remnant stack); rejoin the physical pieces so
          // later content-addressed moves see the same stack.
          const [before, after] = iso.remnants;
          const r = planMerge(sim, after!, before!, "right", pendingHand);
          push(r.prims, r.sim);
        }
        if (m.hasOnto) {
          const [, dst, res] = m.groups;
          const r = planMerge(sim, [m.card!], dst!, sideOf(res!, m.card!), pendingHand);
          push(r.prims, r.sim);
        }
        break;
      }
      case "push": {
        const [dst, res] = m.groups;
        const r = planMerge(sim, [m.card!], dst!, sideOf(res!, m.card!), pendingHand);
        push(r.prims, r.sim);
        break;
      }
      case "place": {
        if (m.hasOnto) {
          // First contact: the card is still in pendingHand and
          // planMerge drags it straight from the hand. A re-placed
          // anchor (already on the table) merges as a board stack.
          const [dst, res] = m.groups;
          const r = planMerge(sim, [m.card!], dst!, sideOf(res!, m.card!), pendingHand);
          push(r.prims, r.sim);
        } else {
          // Bare anchor: lay it at an open loc sized for the meld
          // it is building toward, so the joiners have room.
          const goalSize = m.hasGoal ? m.groups[0]!.length : 1;
          const prim = makePlaceHand(m.card!, findOpenLoc(sim, goalSize));
          push([prim], applyLocally(sim, prim));
        }
        break;
      }
      default:
        throw new Error(`zig plan: unknown verb in line: ${line}`);
    }
  }
  return out;
}

interface PlanLine {
  readonly verb: string;
  readonly card: Card | null; // place/push/peel/steal name a card
  readonly groups: readonly (readonly Card[])[];
  readonly hasOnto: boolean;
  readonly hasGoal: boolean;
}

function parsePlanLine(line: string): PlanLine {
  const verb = line.split(" ", 1)[0]!;
  const groups = [...line.matchAll(/\[([^\]]*)\]/g)]
    .map(g => g[1]!)
    .filter(s => s !== "COMPLETE")
    .map(parseCardList);
  const namesCard = verb !== "split" && verb !== "merge";
  return {
    verb,
    card: namesCard ? parseCardLabel(line.split(/\s+/)[1]!) : null,
    groups,
    hasOnto: line.includes(" onto "),
    hasGoal: line.includes(" to build an eventual "),
  };
}

/** Which side the mover joined: the result snapshot leads with it for
 *  left, trails for right. Exact-card compare — deck marks make every
 *  card unique, so this cannot misread a twin. */
function sideOf(result: readonly Card[], moverFirst: Card): "left" | "right" {
  return cardKey(result[0]!) === cardKey(moverFirst) ? "left" : "right";
}

function indexOfCard(cards: readonly Card[], target: Card): number {
  const i = cards.findIndex(c => cardKey(c) === cardKey(target));
  if (i < 0) {
    throw new Error(`zig plan: card ${asciiToken(target)} not in its source stack`);
  }
  return i;
}
