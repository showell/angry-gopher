// bfs.ts — BFS puzzle solver. Finds the shortest sequence of moves
// that clears all TROUBLE stacks in a Lyn Rummy board.
//
// TS port of python/bfs.py. The algorithm:
//
//   - Pure BFS by program length, bounded by max_trouble (the
//     `bfsWithCap` inner loop).
//   - Outer iterative-deepening on `max_trouble` (the `solveStateWithDescs`
//     wrapper). Try caps 1, 2, … up to maxTroubleOuter; first cap to
//     find a plan returns it.
//   - Plateau detection: if a cap exhausts naturally with `max_trouble_seen
//     < cap`, no higher cap admits anything new — bail out.
//
// SCOPE NOTE: this v1 port intentionally does NOT include the
// card-tracker liveness accelerator (`_all_trouble_singletons_live` and
// `_any_trouble_singleton_newly_doomed` in the Python). Those are
// optimization filters; correctness is preserved without them. They're
// flagged as TODO and are listed in the task brief as v1-deferrable.
//
// Note also: descriptors are returned as plan-line strings WITH desc
// objects (mirrors python's `solve_state_with_descs`). The
// `solveState` thin wrapper drops the descs.

import {
  type Buckets,
  type FocusedState,
  type RawBuckets,
  classifyBuckets,
  isVictory,
  stateSig,
  troubleCount,
} from "./buckets.ts";
import { enumerateFocused, initialLineage } from "./enumerator.ts";
import { describe, type Desc } from "./move.ts";

export interface PlanLine {
  readonly line: string;
  readonly desc: Desc;
}

export interface BfsResult {
  readonly plan: readonly PlanLine[] | null;
  readonly hitMaxStates: boolean;
  readonly expansions: number;
  readonly seenCount: number;
  readonly maxTroubleSeen: number;
}

export interface CapExhaustion {
  readonly cap: number;
  readonly hitMaxStates: boolean;
  readonly expansions: number;
  readonly seenCount: number;
}

export interface SolveExtResult {
  readonly plan: readonly PlanLine[] | null;
  readonly exhaustions: readonly CapExhaustion[];
}

/**
 * Pure BFS by program length, bounded by max_trouble. States whose
 * total trouble exceeds the cap never enter the frontier. At each
 * level we expand EVERY program of that length, generating all level+1
 * programs, before looking at any longer programs. First victory found
 * at level N returns the (shortest-under-cap) plan.
 *
 * `initial` is a `FocusedState`. Mirrors python's `bfs_with_cap`.
 */
export function bfsWithCap(
  initial: FocusedState,
  maxTrouble: number,
  maxStates: number,
): BfsResult {
  const b = initial.buckets;
  if (troubleCount(b.trouble, b.growing) > maxTrouble) {
    // Cap was the binding constraint — return maxTrouble so caller's
    // plateau check (max_trouble_seen < cap) does not fire.
    return { plan: null, hitMaxStates: false, expansions: 0, seenCount: 0, maxTroubleSeen: maxTrouble };
  }
  if (isVictory(b.trouble, b.growing)) {
    return { plan: [], hitMaxStates: false, expansions: 0, seenCount: 1, maxTroubleSeen: 0 };
  }
  const seen = new Set<string>();
  seen.add(stateSig(b, initial.lineage));
  const initialTc = troubleCount(b.trouble, b.growing);
  // Frontier entries: { tc, state, program }. tc carried so per-level
  // sort doesn't recompute.
  type Entry = { tc: number; state: FocusedState; program: PlanLine[] };
  let currentLevel: Entry[] = [{ tc: initialTc, state: initial, program: [] }];
  let expansions = 0;
  let maxTroubleSeen = initialTc;
  while (currentLevel.length > 0) {
    // Sort within level by tc — lowest-trouble-first means
    // victory-bearing states get expanded earliest.
    currentLevel.sort((a, b) => a.tc - b.tc);
    const nextLevel: Entry[] = [];
    for (const { state, program } of currentLevel) {
      expansions++;
      for (const [desc, newState] of enumerateFocused(state)) {
        const nb = newState.buckets;
        const tc = troubleCount(nb.trouble, nb.growing);
        if (tc > maxTroubleSeen) maxTroubleSeen = tc;
        if (tc > maxTrouble) continue;
        const sig = stateSig(nb, newState.lineage);
        if (seen.has(sig)) continue;
        seen.add(sig);
        const newProgram: PlanLine[] = [...program, { line: describe(desc), desc }];
        if (isVictory(nb.trouble, nb.growing)) {
          return {
            plan: newProgram,
            hitMaxStates: false,
            expansions,
            seenCount: seen.size,
            maxTroubleSeen,
          };
        }
        nextLevel.push({ tc, state: newState, program: newProgram });
      }
      if (expansions >= maxStates) {
        return {
          plan: null,
          hitMaxStates: true,
          expansions,
          seenCount: seen.size,
          maxTroubleSeen,
        };
      }
    }
    currentLevel = nextLevel;
  }
  return { plan: null, hitMaxStates: false, expansions, seenCount: seen.size, maxTroubleSeen };
}

interface SolveOptions {
  readonly maxTroubleOuter?: number;
  readonly maxStates?: number;
}

/**
 * Outer iterative-deepening on maxTrouble. Returns a list of
 * `{ line, desc }` plan entries, or null if no plan within the outer
 * cap. Mirrors python's `solve_state_with_descs`.
 *
 * Accepts either RawBuckets (raw card-list stacks) — classified once
 * at entry via `classifyBuckets` — or already-CCS-shaped Buckets.
 */
export function solveStateWithDescs(
  initial: Buckets | RawBuckets,
  opts: SolveOptions = {},
): readonly PlanLine[] | null {
  const maxTroubleOuter = opts.maxTroubleOuter ?? 8;
  const maxStates = opts.maxStates ?? 10000;

  // Boundary: classify if needed. We detect CCS-shape by sniffing the
  // first non-empty stack — if it has `.kind`, it's a CCS.
  const classified: Buckets = isAlreadyClassified(initial)
    ? initial
    : classifyBuckets(initial as RawBuckets);

  if (troubleCount(classified.trouble, classified.growing) > maxTroubleOuter) {
    return null;
  }
  if (isVictory(classified.trouble, classified.growing)) {
    return [];
  }
  const initialFocused: FocusedState = {
    buckets: classified,
    lineage: initialLineage(classified.trouble, classified.growing),
  };
  for (let cap = 1; cap <= maxTroubleOuter; cap++) {
    const res = bfsWithCap(initialFocused, cap, maxStates);
    if (res.plan !== null) return res.plan;
    // Plateau detection: no higher cap admits anything new.
    if (!res.hitMaxStates && res.maxTroubleSeen < cap) return null;
  }
  return null;
}

/**
 * Diagnostic variant: same algorithm as `solveStateWithDescs` but
 * returns one `CapExhaustion` record per cap that ran without finding
 * a plan. `hitMaxStates: true` records mean the cap aborted on the
 * state budget (a runaway candidate). Used by perf_harness for runaway
 * detection and by budget_sweep for plan-rate-vs-budget analysis.
 */
export function solveStateWithDescsExt(
  initial: Buckets | RawBuckets,
  opts: SolveOptions = {},
): SolveExtResult {
  const maxTroubleOuter = opts.maxTroubleOuter ?? 8;
  const maxStates = opts.maxStates ?? 10000;

  const classified: Buckets = isAlreadyClassified(initial)
    ? initial
    : classifyBuckets(initial as RawBuckets);

  if (troubleCount(classified.trouble, classified.growing) > maxTroubleOuter) {
    return { plan: null, exhaustions: [] };
  }
  if (isVictory(classified.trouble, classified.growing)) {
    return { plan: [], exhaustions: [] };
  }
  const initialFocused: FocusedState = {
    buckets: classified,
    lineage: initialLineage(classified.trouble, classified.growing),
  };
  const exhaustions: CapExhaustion[] = [];
  for (let cap = 1; cap <= maxTroubleOuter; cap++) {
    const res = bfsWithCap(initialFocused, cap, maxStates);
    if (res.plan !== null) return { plan: res.plan, exhaustions };
    exhaustions.push({
      cap,
      hitMaxStates: res.hitMaxStates,
      expansions: res.expansions,
      seenCount: res.seenCount,
    });
    if (!res.hitMaxStates && res.maxTroubleSeen < cap) {
      return { plan: null, exhaustions };
    }
  }
  return { plan: null, exhaustions };
}

/** Thin wrapper returning plan lines (no descs). Mirrors python's
 *  `solve_state`. */
export function solveState(
  initial: Buckets | RawBuckets,
  opts: SolveOptions = {},
): readonly string[] | null {
  const plan = solveStateWithDescs(initial, opts);
  if (plan === null) return null;
  return plan.map(p => p.line);
}

function isAlreadyClassified(initial: Buckets | RawBuckets): initial is Buckets {
  for (const bucketName of ["helper", "trouble", "growing", "complete"] as const) {
    const bucket = (initial as { [k: string]: unknown })[bucketName];
    if (Array.isArray(bucket) && bucket.length > 0) {
      const first = bucket[0];
      // CCS has `.kind` and `.cards`; raw is just an array of cards.
      return typeof first === "object" && first !== null && "kind" in first;
    }
  }
  // All buckets empty — treat as classified (Buckets type satisfies both
  // shapes when empty).
  return true;
}
