// engine_v2.ts — kitchen-table algorithm.
//
// Same boundary interface as bfs.ts (Buckets in, PlanLine[]|null out)
// but structured around backtracking + per-card enumeration rather
// than parallel BFS over a frontier.
//
// See claude-steve/random234.md for the algorithmic description.

import type { Buckets, RawBuckets, Lineage } from "./buckets.ts";
import {
  isVictory, stateSig, fastStateSig, buildCardOrder,
  classifyBuckets, troubleCount,
} from "./buckets.ts";
import type { ClassifiedCardStack } from "../core/card_stack.ts";
import { type Move, describe } from "./move.ts";
import { enumerateMoves } from "./enumerator.ts";
import {
  allTroubleSingletonsLive,
  anyTroubleSingletonNewlyDoomed,
} from "./card_neighbors.ts";

export interface PlanLine {
  readonly line: string;
  readonly move: Move;
}

export interface SolveResult {
  readonly plan: readonly PlanLine[];
  readonly finalBuckets: Buckets;
}

interface SolveOptions {
  readonly maxDepth?: number;
}

interface SolveCtxPlus extends SolveCtx {
  readonly maxTrouble: number;
}

/**
 * Top-level entry. Returns the SHORTEST plan found (or null) via
 * iterative deepening: try maxDepth=1, then 2, … up to opts.maxDepth.
 * The first iteration that finds a plan returns it (guaranteed
 * optimal because deeper iterations would only find longer plans
 * via the same search shape).
 *
 * Each iteration is a fresh search — no memoization across the outer
 * loop. Mirrors the kitchen-table "look for 1-motion moves, then
 * 2-motion moves, …" discipline.
 */
export type Heuristic = (b: Buckets) => number;

export const HEURISTICS: Record<string, Heuristic> = {
  /** Lower-bound: each move shrinks trouble+growing by ≤2. Admissible. */
  half_debt: (b) => {
    let n = 0;
    for (const s of b.trouble) n += s.n;
    for (const s of b.growing) n += s.n;
    return Math.ceil(n / 2);
  },
  /** Lower-bound but allow up to 3 cards retired per move (graduating
   *  via a length-3 group from scratch). Tighter (= smaller h), still
   *  admissible. */
  third_debt: (b) => {
    let n = 0;
    for (const s of b.trouble) n += s.n;
    for (const s of b.growing) n += s.n;
    return Math.ceil(n / 3);
  },
  /** Raw trouble-card count. Overestimates → INADMISSIBLE; may miss
   *  optimal but explores fewer states. */
  raw_debt: (b) => {
    let n = 0;
    for (const s of b.trouble) n += s.n;
    for (const s of b.growing) n += s.n;
    return n;
  },
  /** Number of trouble ENTRIES (not cards). Singletons count = pairs.
   *  Roughly "how many subgoals remain." */
  entry_count: (b) => b.trouble.length + b.growing.length,
  /** Mixed: half-debt + small bonus for length-2 partials (they need
   *  extension; length-1 singletons can sometimes be cheaply pushed). */
  weighted: (b) => {
    let cards = 0, partials = 0;
    for (const s of b.trouble) { cards += s.n; if (s.n === 2) partials++; }
    for (const s of b.growing) { cards += s.n; if (s.n === 2) partials++; }
    return Math.ceil(cards / 2) + Math.floor(partials / 2);
  },
  /** Inadmissible: penalize trouble quadratically. 6 cards feels ~5×
   *  worse than 3 cards (per Steve's "Kasparov heuristic"). */
  quadratic: (b) => {
    let n = 0;
    for (const s of b.trouble) n += s.n;
    for (const s of b.growing) n += s.n;
    return Math.ceil((n * n) / 6);
  },
  /** Inadmissible: superlinear with a sharper kick above 4 cards. */
  superlinear: (b) => {
    let n = 0;
    for (const s of b.trouble) n += s.n;
    for (const s of b.growing) n += s.n;
    if (n <= 4) return n;
    return 4 + (n - 4) * 3;  // each card past 4 is "worth" 3
  },
  /** Inadmissible: each trouble entry adds a fixed step + linear card
   *  cost. Penalizes "many disjoint subgoals" framing. */
  many_subgoals: (b) => {
    let entries = b.trouble.length + b.growing.length;
    let cards = 0;
    for (const s of b.trouble) cards += s.n;
    for (const s of b.growing) cards += s.n;
    return entries + Math.ceil(cards / 2);
  },
};

export function solveTurn(
  initial: Buckets,
  opts: SolveOptions & {
    budget?: number;
    heuristic?: Heuristic;
    dedup?: boolean;
    sigKind?: "fast" | "string";
    /** Hard cap on plan length. Branches with `plan.length >=
     *  maxPlanLength` are never pushed. Set this for hint paths
     *  where multi-step plans aren't worth the search cost — humans
     *  who can execute a 5+ step hint usually prefer hunting the
     *  moves themselves. Leave undefined for "complete" solve work
     *  (e.g. proving no_plan in conformance tests). */
    maxPlanLength?: number;
  } = {},
): SolveResult | null {
  const budget = opts.budget ?? 50000;
  const maxPlanLength = opts.maxPlanLength;
  const h = opts.heuristic ?? HEURISTICS.half_debt!;
  const dedup = opts.dedup !== false;  // dedup defaults to ON
  const useFastSig = opts.sigKind !== "string";
  const cardOrderInfo = useFastSig ? buildCardOrder(initial) : null;
  const sigFn = useFastSig
    ? (b: Buckets, lin?: Lineage): string => fastStateSig(b, lin, cardOrderInfo!.posOf, cardOrderInfo!.cardOrder.length)
    : (b: Buckets, lin?: Lineage): string => stateSig(b, lin);
  const initialQueue: ClassifiedCardStack[] = [...initial.trouble, ...initial.growing];

  type Entry = {
    buckets: Buckets;
    queue: readonly ClassifiedCardStack[];
    plan: readonly PlanLine[];
    score: number;
  };
  const pq = new MinHeap<Entry>((a, b) => a.score - b.score);
  const closed = new Set<string>();
  const queueToLineage = (q: readonly ClassifiedCardStack[]): Lineage =>
    q.map(s => [...s.cards]);

  pq.push({ buckets: initial, queue: initialQueue, plan: [], score: h(initial) });

  let best: SolveResult | null = null;
  let visits = 0;
  while (pq.size() > 0 && visits < budget) {
    const cur = pq.pop()!;
    if (best !== null && cur.plan.length >= best.plan.length) continue;
    if (dedup) {
      const sig = sigFn(cur.buckets, queueToLineage(cur.queue));
      if (closed.has(sig)) continue;
      closed.add(sig);
    }
    void initialQueue;
    visits++;
    if (cur.queue.length === 0) {
      if (isVictory(cur.buckets.trouble, cur.buckets.growing)) {
        if (best === null || cur.plan.length < best.plan.length) {
          best = { plan: [...cur.plan], finalBuckets: cur.buckets };
        }
      }
      continue;
    }
    const focus = cur.queue[0]!;
    const parentCompleteCount = cur.buckets.complete.length;
    const candidates = enumerateForFocus(cur.buckets, focus, new Set<string>());
    for (const cand of candidates) {
      const newPlan = [...cur.plan, { line: describe(cand.move), move: cand.move }];
      if (best !== null && newPlan.length >= best.plan.length) continue;
      if (maxPlanLength !== undefined && newPlan.length > maxPlanLength) continue;
      // Dynamic doomed-singleton prune: a child state where a group
      // just graduated may have left a trouble singleton stranded
      // (its last partner sealed into COMPLETE). Gate on
      // complete-count growth — that's the only way a partner can
      // transition out of the accessible pool mid-search.
      if (cand.afterBuckets.complete.length > parentCompleteCount
          && anyTroubleSingletonNewlyDoomed(cand.afterBuckets)) {
        continue;
      }
      const newQueue = computeQueueAfter(cur.queue, focus, cand, cand.afterBuckets);
      const score = newPlan.length + h(cand.afterBuckets);
      pq.push({ buckets: cand.afterBuckets, queue: newQueue, plan: newPlan, score });
    }
  }
  lastVisits = visits;
  return best;
}

// --- Production shim --------------------------------------------------------
//
// `solveStateWithMoves` auto-classifies raw input, short-circuits
// trouble-cap + victory states, then dispatches to `solveTurn` (A*).
// `maxStates` maps to `solveTurn`'s visit `budget`; `maxTroubleOuter`
// is a pre-flight reject for unsolvably-deep inputs.

interface ShimSolveOptions {
  readonly maxStates?: number;
  readonly maxTroubleOuter?: number;
  readonly heuristic?: Heuristic;
  readonly dedup?: boolean;
  readonly sigKind?: "fast" | "string";
  readonly maxPlanLength?: number;
}

function isAlreadyClassified(initial: Buckets | RawBuckets): initial is Buckets {
  for (const bucketName of ["helper", "trouble", "growing", "complete"] as const) {
    const bucket = (initial as unknown as { [k: string]: unknown })[bucketName];
    if (Array.isArray(bucket) && bucket.length > 0) {
      const first = bucket[0];
      return typeof first === "object" && first !== null && "kind" in first;
    }
  }
  return true;
}

export function solveStateWithMoves(
  initial: Buckets | RawBuckets,
  opts: ShimSolveOptions = {},
): SolveResult | null {
  const maxStates = opts.maxStates ?? 50000;
  const maxTroubleOuter = opts.maxTroubleOuter ?? 8;

  const classified: Buckets = isAlreadyClassified(initial)
    ? initial
    : classifyBuckets(initial as RawBuckets);

  if (troubleCount(classified.trouble, classified.growing) > maxTroubleOuter) {
    return null;
  }
  if (isVictory(classified.trouble, classified.growing)) {
    return { plan: [], finalBuckets: classified };
  }
  // Pre-flight: short-circuit if any trouble singleton has no
  // accessible partner pair anywhere in helper ∪ trouble ∪ growing.
  // Such a state is provably unwinnable; A* can't prove it cheaply on
  // its own. Backed by card_neighbors.NEIGHBORS (constant-time per
  // singleton; only fires when trouble has at least one singleton).
  if (!allTroubleSingletonsLive(classified)) {
    return null;
  }

  return solveTurn(classified, {
    budget: maxStates,
    heuristic: opts.heuristic,
    dedup: opts.dedup,
    sigKind: opts.sigKind,
    maxPlanLength: opts.maxPlanLength,
  });
}

/** Thin wrapper that drops the structured Moves and returns just
 *  the rendered plan-line strings. */
export function solveState(
  initial: Buckets | RawBuckets,
  opts: ShimSolveOptions = {},
): readonly string[] | null {
  const result = solveStateWithMoves(initial, opts);
  if (result === null) return null;
  return result.plan.map(p => p.line);
}

class MinHeap<T> {
  private a: T[] = [];
  private cmp: (x: T, y: T) => number;
  constructor(cmp: (x: T, y: T) => number) { this.cmp = cmp; }
  size(): number { return this.a.length; }
  push(x: T): void {
    this.a.push(x);
    let i = this.a.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.cmp(this.a[i]!, this.a[p]!) < 0) {
        [this.a[i], this.a[p]] = [this.a[p]!, this.a[i]!];
        i = p;
      } else break;
    }
  }
  pop(): T | undefined {
    if (this.a.length === 0) return undefined;
    const top = this.a[0]!;
    const last = this.a.pop()!;
    if (this.a.length > 0) {
      this.a[0] = last;
      let i = 0;
      while (true) {
        const l = 2 * i + 1, r = 2 * i + 2;
        let s = i;
        if (l < this.a.length && this.cmp(this.a[l]!, this.a[s]!) < 0) s = l;
        if (r < this.a.length && this.cmp(this.a[r]!, this.a[s]!) < 0) s = r;
        if (s === i) break;
        [this.a[i], this.a[s]] = [this.a[s]!, this.a[i]!];
        i = s;
      }
    }
    return top;
  }
}

interface SolveCtx {
  best: PlanLine[] | null;
  readonly maxDepth: number;
  visits: number;
}

export let lastVisits = 0;

function solveRec(
  buckets: Buckets,
  queue: readonly ClassifiedCardStack[],
  plan: readonly PlanLine[],
  doomedPairs: Set<string>,
  ctx: SolveCtx,
): void {
  ctx.visits++;
  // Pruning: if current plan length already >= best-known length,
  // any extension is guaranteed worse.
  if (ctx.best !== null && plan.length >= ctx.best.length) return;

  // Trouble-cap pruning: total trouble + growing card count must
  // stay within ctx.maxTrouble.
  const ctxPlus = ctx as SolveCtxPlus;
  if (ctxPlus.maxTrouble !== undefined) {
    let n = 0;
    for (const s of buckets.trouble) n += s.n;
    for (const s of buckets.growing) n += s.n;
    if (n > ctxPlus.maxTrouble) return;
  }

  // Hard depth bound (safety net).
  if (plan.length > ctx.maxDepth) return;

  if (queue.length === 0) {
    if (isVictory(buckets.trouble, buckets.growing)) {
      // Found a complete plan; record if it's the shortest so far.
      if (ctx.best === null || plan.length < ctx.best.length) {
        ctx.best = [...plan];
      }
    }
    return;
  }

  const focus = queue[0]!;
  const candidates = enumerateForFocus(buckets, focus, doomedPairs);
  if (candidates.length === 0) return; // QUIT this branch

  for (const cand of candidates) {
    // Pruning re-check inside the loop in case best updated since
    // entry (siblings can update it).
    if (ctx.best !== null && plan.length + 1 >= ctx.best.length) return;
    const newBuckets = cand.afterBuckets;
    const newQueue = computeQueueAfter(queue, focus, cand, newBuckets);
    const newPlan = [...plan, { line: describe(cand.move), move: cand.move }];
    solveRec(newBuckets, newQueue, newPlan, doomedPairs, ctx);
  }
}

interface Candidate {
  readonly move: Move;
  readonly afterBuckets: Buckets;
}

/** Enumerate the candidates that operate on the focused entry,
 *  ORDERED by cleanness — clean (EXECUTE) candidates first,
 *  messy (CONTINUE) candidates last. Within each tier, prefer the
 *  move that leaves the smallest post-state trouble-count. */
function enumerateForFocus(
  buckets: Buckets,
  focus: ClassifiedCardStack,
  doomedPairs: Set<string>,
): Candidate[] {
  const candidates: { move: Move; afterBuckets: Buckets; tier: number; troubleAfter: number; sourceLen: number }[] = [];
  const focusCards = focus.cards;
  for (const [move, newBuckets] of enumerateMoves(buckets)) {
    if (!moveTouchesFocus(move, focusCards)) continue;
    const tier = candidateTier(move, newBuckets);
    let n = 0;
    for (const s of newBuckets.trouble) n += s.n;
    for (const s of newBuckets.growing) n += s.n;
    const sourceLen = sourceHelperLength(move);
    candidates.push({ move, afterBuckets: newBuckets, tier, troubleAfter: n, sourceLen });
  }
  // Sort by tier ascending (EXECUTE = 0, CONTINUE = 1, …), then by
  // source-helper length ascending (prefer extracts from smaller
  // helpers — preserves big runs for later moves), then by
  // troubleAfter ascending.
  candidates.sort((a, b) => a.tier - b.tier || a.troubleAfter - b.troubleAfter);
  return candidates.map(c => ({ move: c.move, afterBuckets: c.afterBuckets }));
  void doomedPairs;
}

/** Tier 0 = EXECUTE (clean: graduates + no spawn). Tier 1 = CONTINUE
 *  (messy: spawns or non-graduating). */
function candidateTier(move: Move, _newBuckets: Buckets): number {
  switch (move.type) {
    case "extract_absorb":
      if (move.graduated && move.spawned.length === 0) return 0;
      return 1;
    case "free_pull":
      return move.graduated ? 0 : 1;
    case "shift":
      return move.graduated ? 0 : 1;
    case "push":
      return 0; // push consumes trouble, never spawns
    case "splice":
      return 1; // splice always splits a helper
  }
  return 1;
  void _newBuckets;
}

/** Return the length of the helper that the Move's extract operates
 *  on, for tie-breaking. Larger helpers are more useful future
 *  donors, so we prefer extracting from smaller ones first. */
function sourceHelperLength(move: Move): number {
  switch (move.type) {
    case "extract_absorb":
    case "shift":
      return move.source.length;
    case "splice":
      return move.source.length;
    case "free_pull":
    case "push":
      return 0;
  }
  return 0;
}

/** Move "touches" focus if it consumes/grows the entry whose cards
 *  equal `focus`. */
function moveTouchesFocus(move: Move, focus: readonly Card[]): boolean {
  if (move.type === "extract_absorb" || move.type === "shift") {
    return cardsEqual(move.targetBefore, focus);
  }
  if (move.type === "free_pull") {
    if (cardsEqual(move.targetBefore, focus)) return true;
    return focus.length === 1 && cardEqual(focus[0]!, move.loose);
  }
  if (move.type === "splice") {
    return focus.length === 1 && cardEqual(focus[0]!, move.loose);
  }
  if (move.type === "push") {
    return cardsEqual(move.troubleBefore, focus);
  }
  return false;
}

import type { Card } from "../core/card.ts";

function cardEqual(a: Card, b: Card): boolean {
  return a.rank === b.rank && a.suit === b.suit && a.deck === b.deck;
}
function cardsEqual(a: readonly Card[], b: readonly Card[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (!cardEqual(a[i]!, b[i]!)) return false;
  return true;
}

/** After applying the move, compute the new queue. */
function computeQueueAfter(
  queue: readonly ClassifiedCardStack[],
  focus: ClassifiedCardStack,
  cand: Candidate,
  newBuckets: Buckets,
): readonly ClassifiedCardStack[] {
  // Drop the focus from queue.
  const rest = queue.slice(1);

  // Did focus survive the move? If so, find its new form (still
  // present in trouble or growing) and prepend it.
  // For the simplest implementation: rebuild the queue from the new
  // buckets, preserving the order of `rest` for entries that are
  // identical, and appending any "new" entries (spawns / merge results)
  // at the end.
  const survivingByCards = new Map<string, ClassifiedCardStack>();
  for (const stack of [...newBuckets.trouble, ...newBuckets.growing]) {
    survivingByCards.set(cardsKey(stack.cards), stack);
  }

  const newQueue: ClassifiedCardStack[] = [];
  // For each entry in rest that still exists, keep it.
  const used = new Set<string>();
  for (const e of rest) {
    const k = cardsKey(e.cards);
    if (survivingByCards.has(k) && !used.has(k)) {
      newQueue.push(survivingByCards.get(k)!);
      used.add(k);
    }
  }
  // For every other surviving entry (the new-or-changed-shape ones),
  // append in their bucket-iteration order.
  for (const stack of [...newBuckets.trouble, ...newBuckets.growing]) {
    const k = cardsKey(stack.cards);
    if (used.has(k)) continue;
    newQueue.push(stack);
    used.add(k);
  }

  return newQueue;
  void focus;
  void cand;
}

function cardsKey(cards: readonly Card[]): string {
  return cards.map(c => `${c.rank},${c.suit},${c.deck}`).join("|");
}
