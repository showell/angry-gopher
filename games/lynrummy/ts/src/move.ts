// move.ts — BFS descriptor types + plan-line rendering.
//
// TS port of python/move.py. Each move type has a dedicated descriptor
// shape mirroring the python dataclass field set. The enumerator emits
// these; readers dispatch on the `type` discriminator.
//
// Descriptors carry RAW card tuples / card lists, NOT CCS objects, for
// plan-line stability and downstream serialization. Mirroring the
// python field layout exactly keeps the cross-language plan-line check
// trivial (string equality, no normalization).

import type { Card } from "./rules/card.ts";
import { RANKS, SUITS, cardLabel } from "./rules/card.ts";

/** Side discriminator for absorb/splice variants. Mirrors python's
 *  `Side`. Only data-layout-level — no function takes `side` as a
 *  parameter (per SOLVER.md's discipline). */
export type Side = "left" | "right";

/** Source verb that produced an extract. Mirrors python's `Verb`. */
export type Verb = "peel" | "pluck" | "yank" | "steal" | "split_out";

/** Bucket where the absorb target came from. Same alphabet as
 *  `BucketName` in buckets.ts. */
export type AbsorberBucket = "trouble" | "growing";

// --- Descriptors -----------------------------------------------------------
//
// Each interface mirrors the python dataclass field-for-field. The
// `type` literal field discriminates them.

export interface ExtractAbsorbDesc {
  readonly type: "extract_absorb";
  readonly verb: Verb;
  readonly source: readonly Card[];
  readonly extCard: Card;
  readonly targetBefore: readonly Card[];
  readonly targetBucketBefore: AbsorberBucket;
  readonly result: readonly Card[];
  readonly side: Side;
  readonly graduated: boolean;
  readonly spawned: readonly (readonly Card[])[];
}

export interface FreePullDesc {
  readonly type: "free_pull";
  readonly loose: Card;
  readonly targetBefore: readonly Card[];
  readonly targetBucketBefore: AbsorberBucket;
  readonly result: readonly Card[];
  readonly side: Side;
  readonly graduated: boolean;
}

export interface PushDesc {
  readonly type: "push";
  readonly troubleBefore: readonly Card[];
  readonly targetBefore: readonly Card[];
  readonly result: readonly Card[];
  readonly side: Side;
}

export interface SpliceDesc {
  readonly type: "splice";
  readonly loose: Card;
  readonly source: readonly Card[];
  readonly k: number;
  readonly side: Side;
  readonly leftResult: readonly Card[];
  readonly rightResult: readonly Card[];
}

export interface ShiftDesc {
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
 *  separates the cards. See `random233.md`. */
export interface DecomposeDesc {
  readonly type: "decompose";
  readonly pairBefore: readonly Card[];   // 2-card pair being split
  readonly leftCard: Card;
  readonly rightCard: Card;
}

/** Discriminated union over all move descriptors. */
export type Desc =
  | ExtractAbsorbDesc
  | FreePullDesc
  | PushDesc
  | SpliceDesc
  | ShiftDesc
  | DecomposeDesc;

// --- Plan-line rendering ---------------------------------------------------
//
// `describe(desc)` produces the canonical one-line DSL string. The
// strings here are the cross-language contract — they must exactly
// match python's `move.describe(desc)` output.

function stackLabel(stack: readonly Card[]): string {
  return stack.map(cardLabel).join(" ");
}

/**
 * Render a one-line DSL string for a move. Mirrors python's
 * `move.describe`. Must match python output exactly — this is the
 * cross-language contract.
 */
export function describe(desc: Desc): string {
  switch (desc.type) {
    case "free_pull": {
      const graduated = desc.graduated ? " [→COMPLETE]" : "";
      return `pull ${cardLabel(desc.loose)} onto ${desc.targetBucketBefore} `
        + `[${stackLabel(desc.targetBefore)}] → `
        + `[${stackLabel(desc.result)}]${graduated}`;
    }
    case "extract_absorb": {
      let spawnedStr = "";
      if (desc.spawned.length > 0) {
        spawnedStr = " ; spawn TROUBLE: "
          + desc.spawned.map(s => "[" + stackLabel(s) + "]").join(", ");
      }
      const graduated = desc.graduated ? " [→COMPLETE]" : "";
      return `${desc.verb} ${cardLabel(desc.extCard)} from HELPER `
        + `[${stackLabel(desc.source)}], `
        + `absorb onto ${desc.targetBucketBefore} `
        + `[${stackLabel(desc.targetBefore)}] → `
        + `[${stackLabel(desc.result)}]`
        + `${graduated}${spawnedStr}`;
    }
    case "shift": {
      const p = cardLabel(desc.pCard);
      // Determine whether p ended up at index 0 or last (Python uses
      // .index(p_card) on new_source then enumerates rest in order).
      let pIdx = -1;
      for (let i = 0; i < desc.newSource.length; i++) {
        const c = desc.newSource[i]!;
        if (c[0] === desc.pCard[0] && c[1] === desc.pCard[1] && c[2] === desc.pCard[2]) {
          pIdx = i;
          break;
        }
      }
      const rest: Card[] = [];
      for (const c of desc.newSource) {
        if (!(c[0] === desc.pCard[0] && c[1] === desc.pCard[1] && c[2] === desc.pCard[2])) {
          rest.push(c);
        }
      }
      const restLabel = rest.map(cardLabel).join(" ");
      const shifted = pIdx === 0
        ? `${p} + ${restLabel}`
        : `${restLabel} + ${p}`;
      const graduated = desc.graduated ? " [→COMPLETE]" : "";
      return `shift ${p} to pop ${cardLabel(desc.stolen)} `
        + `[${stackLabel(desc.newDonor)} -> ${shifted}]; `
        + `absorb onto ${desc.targetBucketBefore} `
        + `[${stackLabel(desc.targetBefore)}] → `
        + `[${stackLabel(desc.merged)}]${graduated}`;
    }
    case "splice": {
      return `splice [${cardLabel(desc.loose)}] into HELPER `
        + `[${stackLabel(desc.source)}] → `
        + `[${stackLabel(desc.leftResult)}] + `
        + `[${stackLabel(desc.rightResult)}]`;
    }
    case "push": {
      return `push TROUBLE [${stackLabel(desc.troubleBefore)}] onto HELPER `
        + `[${stackLabel(desc.targetBefore)}] → `
        + `[${stackLabel(desc.result)}]`;
    }
    case "decompose": {
      return `decompose TROUBLE [${stackLabel(desc.pairBefore)}] → `
        + `[${cardLabel(desc.leftCard)}] + [${cardLabel(desc.rightCard)}]`;
    }
  }
}

// --- Narrate / hint --------------------------------------------------------
//
// These are convenience renderers used by enumerate_moves conformance
// scenarios that assert `narrate_contains` or `hint_contains`. The
// outputs only need to MATCH on the substring — full output equality
// against python is NOT required (different code paths consume them).

/** Family-kind classifier used for narrate/hint phrasing. Returns
 *  "set" / "pure_run" / "rb_run" / "other". A simplified version of
 *  python's rules.classify; only correct on length-3+ legal stacks. */
function classifyFamily(stack: readonly Card[]): string {
  const n = stack.length;
  if (n < 3) return "other";
  const c0 = stack[0]!;
  const c1 = stack[1]!;
  // Set: same value, distinct suits.
  if (c0[0] === c1[0]) {
    const seen = new Set<number>();
    for (const c of stack) {
      if (c[0] !== c0[0]) return "other";
      if (seen.has(c[1])) return "other";
      seen.add(c[1]);
    }
    return "set";
  }
  // Run: successive values, same-suit (pure) or alternating-color (rb).
  const succ = (v: number) => v === 13 ? 1 : v + 1;
  if (succ(c0[0]) !== c1[0]) return "other";
  const RED = new Set([1, 3]);
  if (c0[1] === c1[1]) {
    let prevV = c1[0];
    for (let i = 2; i < n; i++) {
      const c = stack[i]!;
      if (c[0] !== succ(prevV) || c[1] !== c0[1]) return "other";
      prevV = c[0];
    }
    return "pure_run";
  }
  if (RED.has(c0[1]) === RED.has(c1[1])) return "other";
  let prevV = c1[0];
  let prevRed = RED.has(c1[1]);
  for (let i = 2; i < n; i++) {
    const c = stack[i]!;
    if (c[0] !== succ(prevV)) return "other";
    const cRed = RED.has(c[1]);
    if (cRed === prevRed) return "other";
    prevV = c[0];
    prevRed = cRed;
  }
  return "rb_run";
}

function groupKindPhrase(stack: readonly Card[]): string {
  const k = classifyFamily(stack);
  if (k === "set") return "a set";
  if (k === "pure_run") return "a pure run";
  if (k === "rb_run") return "a red-black run";
  return "a partial";
}

function partialKindPhrase(stack: readonly Card[]): string {
  const n = stack.length;
  if (n === 0) return "an empty target";
  if (n === 1) return `the ${cardLabel(stack[0]!)}`;
  return "the partial [" + stack.map(cardLabel).join(" ") + "]";
}

function runKindPhrase(stack: readonly Card[]): string {
  const k = classifyFamily(stack);
  if (k === "pure_run") return "pure run";
  if (k === "rb_run") return "red-black run";
  return "run";
}

/** Evocative one-liner for a move (intent over mechanics). Mirrors
 *  python's `move.narrate` — used by conformance `narrate_contains`. */
export function narrate(desc: Desc): string {
  switch (desc.type) {
    case "free_pull": {
      const check = desc.graduated ? " ✓" : "";
      return `pull ${cardLabel(desc.loose)} into [${stackLabel(desc.result)}]${check}`;
    }
    case "extract_absorb": {
      const check = desc.graduated ? " ✓" : "";
      let spawnedStr = "";
      if (desc.spawned.length > 0) {
        spawnedStr = " (leaves "
          + desc.spawned.map(s => "[" + stackLabel(s) + "]").join(", ")
          + " homeless)";
      }
      return `${desc.verb} ${cardLabel(desc.extCard)} → `
        + `[${stackLabel(desc.result)}]${check}${spawnedStr}`;
    }
    case "shift": {
      const check = desc.graduated ? " ✓" : "";
      return `${cardLabel(desc.pCard)} pops ${cardLabel(desc.stolen)} → `
        + `[${stackLabel(desc.merged)}]${check}`;
    }
    case "splice":
      return `splice ${cardLabel(desc.loose)} → `
        + `[${stackLabel(desc.leftResult)}] + [${stackLabel(desc.rightResult)}]`;
    case "push": {
      // Engulf-shape vs plain push: engulf produces a length-3+ legal
      // group from a growing-style merge.
      if (classifyFamily(desc.result) !== "other") {
        return `engulf [${stackLabel(desc.targetBefore)}] into `
          + `[${stackLabel(desc.troubleBefore)}] → `
          + `[${stackLabel(desc.result)}] ✓`;
      }
      return `tuck [${stackLabel(desc.troubleBefore)}] into `
        + `[${stackLabel(desc.targetBefore)}] → `
        + `[${stackLabel(desc.result)}]`;
    }
    case "decompose":
      return `decompose [${stackLabel(desc.pairBefore)}] into singletons`;
  }
}

/** Vague hint for a HUMAN PLAYER. Mirrors python's `move.hint`. May
 *  return null (e.g., extract_absorb verbs that are too specific). */
export function hint(desc: Desc): string | null {
  switch (desc.type) {
    case "free_pull":
      return `You can pull the ${cardLabel(desc.loose)} onto `
        + `${groupKindPhrase(desc.result)}.`;
    case "extract_absorb":
      return `You can ${desc.verb} the ${cardLabel(desc.extCard)} to `
        + `extend ${partialKindPhrase(desc.targetBefore)}.`;
    case "shift":
      return `You can pop the ${cardLabel(desc.stolen)} by shifting `
        + `the ${cardLabel(desc.pCard)} into the run.`;
    case "splice":
      return `You can splice the ${cardLabel(desc.loose)} into a `
        + `${runKindPhrase(desc.source)}.`;
    case "push":
      if (classifyFamily(desc.result) !== "other") {
        return `You can complete a run by absorbing [${stackLabel(desc.troubleBefore)}].`;
      }
      return `You can tuck [${stackLabel(desc.troubleBefore)}] back into a run.`;
    case "decompose":
      return `You can split the [${stackLabel(desc.pairBefore)}] pair apart.`;
  }
}
