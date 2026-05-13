// move.ts — BFS Move descriptors + plan-line rendering.
//
// A `Move` is one verb-level step in the BFS's plan. The solver
// returns a sequence of Moves; `physicalPlan` lowers each Move into
// the `Primitive` sequence that realizes it on a geometric board.
//
// Each Move variant carries RAW card tuples (not CCS objects), so
// `describe(move)` produces a stable plan-line string suitable for
// cross-language pinning.

import { type Card, RANKS, SUITS, cardLabel } from "../core/card.ts";
import {
  isCompleteGroup,
  groupKindPhrase,
  partialKindPhrase,
  runKindPhrase,
} from "../core/card_stack.ts";

export type Side = "left" | "right";

/** Verb name attached to an extract-absorb Move. `set_peel` is the
 *  SET-specific length-3 case where the remnant pair stays coherent
 *  in GROWING (instead of being shattered into singletons by `steal`). */
export type Verb = "peel" | "pluck" | "yank" | "steal" | "split_out" | "set_peel";

/** Bucket the absorb target came from. Same alphabet as `BucketName`
 *  in buckets.ts. */
export type AbsorberBucket = "trouble" | "growing";

export interface ExtractAbsorbMove {
  readonly type: "extract_absorb";
  readonly verb: Verb;
  readonly source: readonly Card[];
  readonly extCard: Card;
  readonly targetBefore: readonly Card[];
  readonly targetBucketBefore: AbsorberBucket;
  readonly result: readonly Card[];
  readonly side: Side;
  readonly graduated: boolean;
  /** Stacks the extract spawned that land in TROUBLE (singletons
   *  from set-shattering steals; doomed run/rb halves from yank). */
  readonly spawned: readonly (readonly Card[])[];
  /** Stacks the extract spawned that land in GROWING (pair-shape
   *  remnants — only `set_peel` produces these today). */
  readonly spawnedGrowing: readonly (readonly Card[])[];
}

export interface FreePullMove {
  readonly type: "free_pull";
  readonly loose: Card;
  readonly targetBefore: readonly Card[];
  readonly targetBucketBefore: AbsorberBucket;
  readonly result: readonly Card[];
  readonly side: Side;
  readonly graduated: boolean;
}

export interface PushMove {
  readonly type: "push";
  readonly troubleBefore: readonly Card[];
  readonly targetBefore: readonly Card[];
  readonly result: readonly Card[];
  readonly side: Side;
}

export interface SpliceMove {
  readonly type: "splice";
  readonly loose: Card;
  readonly source: readonly Card[];
  readonly k: number;
  readonly side: Side;
  readonly leftResult: readonly Card[];
  readonly rightResult: readonly Card[];
}

export interface ShiftMove {
  readonly type: "shift";
  readonly source: readonly Card[];
  readonly donor: readonly Card[];
  readonly stolen: Card;
  readonly pCard: Card;
  readonly whichEnd: number;
  readonly newSource: readonly Card[];
  readonly newDonor: readonly Card[];
  readonly targetBefore: readonly Card[];
  readonly targetBucketBefore: AbsorberBucket;
  readonly merged: readonly Card[];
  readonly side: Side;
  readonly graduated: boolean;
}

/** Decompose: split a TROUBLE pair (pair_run / pair_rb / pair_set)
 *  back into two singletons. The bundling that pair-spawning moves
 *  produce isn't a real game commitment — sometimes the right play
 *  separates the cards. */
export interface DecomposeMove {
  readonly type: "decompose";
  readonly pairBefore: readonly Card[];
  readonly leftCard: Card;
  readonly rightCard: Card;
}

export type Move =
  | ExtractAbsorbMove
  | FreePullMove
  | PushMove
  | SpliceMove
  | ShiftMove
  | DecomposeMove;

// --- Plan-line rendering ---------------------------------------------------
//
// `describe(move)` produces the canonical one-line DSL string. The
// strings here are the cross-language contract — they must exactly
// match the strings Python emits (and what conformance fixtures pin).
// Bucket markers (TROUBLE / GROWING) are deliberately NOT in the
// rendered line; bucket assignment lives in the structured Move.

function stackLabel(stack: readonly Card[]): string {
  return stack.map(cardLabel).join(" ");
}

export function describe(move: Move): string {
  switch (move.type) {
    case "free_pull": {
      const graduated = move.graduated ? " [→COMPLETE]" : "";
      return `pull ${cardLabel(move.loose)} onto `
        + `[${stackLabel(move.targetBefore)}] → `
        + `[${stackLabel(move.result)}]${graduated}`;
    }
    case "extract_absorb": {
      let spawnedStr = "";
      const allSpawned = [...move.spawned, ...move.spawnedGrowing];
      if (allSpawned.length > 0) {
        spawnedStr = " ; spawn "
          + allSpawned.map(s => "[" + stackLabel(s) + "]").join(", ");
      }
      const graduated = move.graduated ? " [→COMPLETE]" : "";
      return `${move.verb} ${cardLabel(move.extCard)} from HELPER `
        + `[${stackLabel(move.source)}], `
        + `absorb onto `
        + `[${stackLabel(move.targetBefore)}] → `
        + `[${stackLabel(move.result)}]`
        + `${graduated}${spawnedStr}`;
    }
    case "shift": {
      const p = cardLabel(move.pCard);
      // Determine whether p ended up at index 0 or last (Python uses
      // .index(p_card) on new_source then enumerates rest in order).
      let pIdx = -1;
      for (let i = 0; i < move.newSource.length; i++) {
        const c = move.newSource[i]!;
        if (c.rank === move.pCard.rank && c.suit === move.pCard.suit && c.deck === move.pCard.deck) {
          pIdx = i;
          break;
        }
      }
      const rest: Card[] = [];
      for (const c of move.newSource) {
        if (!(c.rank === move.pCard.rank && c.suit === move.pCard.suit && c.deck === move.pCard.deck)) {
          rest.push(c);
        }
      }
      const restLabel = rest.map(cardLabel).join(" ");
      const shifted = pIdx === 0
        ? `${p} + ${restLabel}`
        : `${restLabel} + ${p}`;
      const graduated = move.graduated ? " [→COMPLETE]" : "";
      return `shift ${p} to pop ${cardLabel(move.stolen)} `
        + `[${stackLabel(move.newDonor)} -> ${shifted}]; `
        + `absorb onto `
        + `[${stackLabel(move.targetBefore)}] → `
        + `[${stackLabel(move.merged)}]${graduated}`;
    }
    case "splice": {
      return `splice [${cardLabel(move.loose)}] into HELPER `
        + `[${stackLabel(move.source)}] → `
        + `[${stackLabel(move.leftResult)}] + `
        + `[${stackLabel(move.rightResult)}]`;
    }
    case "push": {
      return `push [${stackLabel(move.troubleBefore)}] onto HELPER `
        + `[${stackLabel(move.targetBefore)}] → `
        + `[${stackLabel(move.result)}]`;
    }
    case "decompose": {
      return `decompose [${stackLabel(move.pairBefore)}] → `
        + `[${cardLabel(move.leftCard)}] + [${cardLabel(move.rightCard)}]`;
    }
  }
}

// --- Narrate / hint --------------------------------------------------------
//
// Convenience renderers used by enumerate_moves conformance scenarios
// that assert `narrate_contains` or `hint_contains`. The outputs only
// need to MATCH on the substring — full output equality against Python
// is NOT required (different code paths consume them).

/** Evocative one-liner for a Move (intent over mechanics). */
export function narrate(move: Move): string {
  switch (move.type) {
    case "free_pull": {
      const check = move.graduated ? " ✓" : "";
      return `pull ${cardLabel(move.loose)} into [${stackLabel(move.result)}]${check}`;
    }
    case "extract_absorb": {
      const check = move.graduated ? " ✓" : "";
      let spawnedStr = "";
      if (move.spawned.length > 0) {
        spawnedStr = " (leaves "
          + move.spawned.map(s => "[" + stackLabel(s) + "]").join(", ")
          + " homeless)";
      }
      return `${move.verb} ${cardLabel(move.extCard)} → `
        + `[${stackLabel(move.result)}]${check}${spawnedStr}`;
    }
    case "shift": {
      const check = move.graduated ? " ✓" : "";
      return `${cardLabel(move.pCard)} pops ${cardLabel(move.stolen)} → `
        + `[${stackLabel(move.merged)}]${check}`;
    }
    case "splice":
      return `splice ${cardLabel(move.loose)} → `
        + `[${stackLabel(move.leftResult)}] + [${stackLabel(move.rightResult)}]`;
    case "push": {
      // Engulf-shape vs plain push: engulf produces a length-3+ legal
      // group from a growing-style merge.
      if (isCompleteGroup(move.result)) {
        return `engulf [${stackLabel(move.targetBefore)}] into `
          + `[${stackLabel(move.troubleBefore)}] → `
          + `[${stackLabel(move.result)}] ✓`;
      }
      return `tuck [${stackLabel(move.troubleBefore)}] into `
        + `[${stackLabel(move.targetBefore)}] → `
        + `[${stackLabel(move.result)}]`;
    }
    case "decompose":
      return `decompose [${stackLabel(move.pairBefore)}] into singletons`;
  }
}

/** Vague hint for a HUMAN player. May return null (e.g.,
 *  extract_absorb verbs that are too specific). */
export function hint(move: Move): string | null {
  switch (move.type) {
    case "free_pull":
      return `You can pull the ${cardLabel(move.loose)} onto `
        + `${groupKindPhrase(move.result)}.`;
    case "extract_absorb":
      return `You can ${move.verb} the ${cardLabel(move.extCard)} to `
        + `extend ${partialKindPhrase(move.targetBefore)}.`;
    case "shift":
      return `You can pop the ${cardLabel(move.stolen)} by shifting `
        + `the ${cardLabel(move.pCard)} into the run.`;
    case "splice":
      return `You can splice the ${cardLabel(move.loose)} into a `
        + `${runKindPhrase(move.source)}.`;
    case "push":
      if (isCompleteGroup(move.result)) {
        return `You can complete a run by absorbing [${stackLabel(move.troubleBefore)}].`;
      }
      return `You can tuck [${stackLabel(move.troubleBefore)}] back into a run.`;
    case "decompose":
      return `You can split the [${stackLabel(move.pairBefore)}] pair apart.`;
  }
}

void RANKS; void SUITS;
