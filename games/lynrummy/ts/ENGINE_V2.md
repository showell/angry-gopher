# engine_v2 — kitchen-table A* solver

**Status (2026-05-02):** v1 landed. Drop-in alternative to `bfs.ts`,
same boundary interface (`Buckets in, PlanLine[] | null out`).
Validated on 116 conformance scenarios (46 easy + 70 medium); zero
correctness regressions. Worst observed wall: ~430ms for an optimal
5-step plan on `corpus_sid_130`.

## What it is

A* priority-queue search built around the kitchen-table algorithm
described in `claude-steve/random234.md`:

- The trouble queue is the unit of progress.
- Each state ranked by `f = plan_length + heuristic(buckets)`.
- Heuristic: `ceil(trouble_debt / 2)` (admissible — each move
  retires at most 2 cards).
- Closed list (state-sig dedup) prevents revisiting equivalent
  states reached via different orderings.

The leaf verb library (`peel`, `pluck`, `yank`, `steal`, `split_out`,
`classifyStack`) is reused unchanged from `classified_card_stack.ts`.
The engine just composes them differently from `bfs.ts`.

## The vocabulary fix

`canSteal` and `steal` were extended to operate on length-2 trouble
partials in addition to length-3 helpers. The "steal-from-partial"
move corresponds to the kitchen-table single-motion act of "I grab
the AS from `[AS 2S]` and absorb it onto `[AC' AD]`; the leftover 2S
becomes a singleton." Without this, the engine had to model that as
a two-step decompose-then-pull, breaking the natural 4-step solution
into 5 awkward steps. See `random234.md` and `random238.md` for the
full reasoning.

## Files

- `src/engine_v2.ts` — the engine + heuristics + min-heap.
- `src/buckets.ts` — `fastStateSig`/`buildCardOrder` for fast
  position-indexed dedup keys (1.2× faster than legacy stateSig).
- `bench/check_baseline_timing.ts` — 81-card timing
  regression check (the standing perf gate).
- `bench/gen_baseline_board.ts` — regenerates the gold
  after a deliberate solver change.
- `bench/end_of_deck_perf.ts` — full-game perf harness; runs
  the 6 standing seeds to deck-low.
- `bench/perf_harness.ts`, `bench/budget_sweep.ts`,
  `bench/bench_timing.ts` — auxiliary measurement drivers.
- `bench/bench_outer_shell.ts` — singleton-only vs full
  outer-shell mode comparison on a fixed 60-hand corpus;
  has its own gold (`bench/bench_outer_shell_gold.txt`).

The one-shot diagnostic benches that lived alongside the
2026-05-02 engine_v2 ramp-up have been retired; commit
history carries the historical record of what was measured
and when.

## Optimization levers explored

Two were investigated in depth on 2026-05-02:

| Lever | Visit reduction | Wall reduction | Status |
|---|---|---|---|
| **A* + admissible heuristic** | replaces iterative deepening; ~5–8× fewer visits than depth-only ID | comparable to ID with trouble-cap | landed |
| **State-sig dedup (closed list)** | ~22% on hard scenarios | ~10–20% on hard | landed |
| Heuristic tuning (5 alternatives) | < 5% spread between admissible variants; aggressive variants didn't help | noise | landed (`half_debt` default) |
| Position-indexed `fastStateSig` | identical to string-sig | ~1.2× faster | landed |
| Pair-doom memo | est. 5–15% wall (likely smaller) | not implemented | deferred — see `random238.md` |
| Beam search / Kasparov pruning | true pruning, not just deprioritization | est. 5–10× but loses optimality | not implemented |
| Doomed-singleton predicate | could catch root-state futility cheaply | not implemented | deferred — see `random226.md` |

Concrete numbers vs the original BFS-with-shift baseline (now
matched or beaten on the conformance corpus):

```
corpus_sid_130:  BFS 1847ms → engine_v2 432ms (5-step optimal)
corpus_sid_116:  BFS 1340ms → engine_v2 605ms (5-step optimal)
corpus_sid_110:  BFS 1124ms → engine_v2 432ms (5-step optimal)
corpus_sid_146:  BFS  450ms → engine_v2 212ms (4-step — engine
                                              found 1 step shorter
                                              than fixture)
```

## When to call which engine

For now the production path uses `bfs.ts` (legacy BFS); engine_v2 is
isolated for experimentation. Reasons we haven't switched yet:

- Conformance fixtures pin specific BFS plan-lines. Switching would
  require updating fixtures or accepting "any valid plan" semantics.
- The original BFS still has a few configurations (shift on, focus
  on) that are well-tuned for everything currently shipping.

When to consider switching:
- A scenario where engine_v2 finds a strictly shorter plan
  (corpus_sid_146 already does; pattern likely repeats in larger
  corpora).
- New move types (e.g., singleton-doom predicate) where engine_v2's
  cleaner structure makes adoption easier.

## Practical framing for shipping

For a shipping hint feature:
- **Instant hints (≤3-step plans):** sub-millisecond. Show
  immediately.
- **Thinking hints (4-5 step plans):** 50–600ms typical. UI shows a
  spinner.
- **Stuck/unsolvable:** the engine returns null after exhausting the
  budget (default 50000 visits ≈ 5–10s worst case). UI shows "no
  plan found at this difficulty."

Most actual gameplay hints are short. The 5-step worst cases are
edge of the conformance corpus, not common play.

## Unexplored, in priority order

1. **Beam search** atop A*. Cap queue size to ~100; evict bad
   states. Trades optimality for big-O speedup. Real-game use case
   if speed matters more than minimality.
2. **Singleton-doom predicate**. At root, prove "this trouble
   singleton has no constructible length-3 group anywhere"; QUIT
   instantly. Inexpensive check, would make pure no_plan cases
   sub-millisecond.
3. **Pair-doom memo**. Cache the per-pair completion-shape work
   across branches. Small win.
4. **Coroutine-scheduled candidate exploration** — see `random236.md`.
   Niche.

## Solver design principles

The engine, the verb library (`classified_card_stack.ts`), and the
move generator (`enumerator.ts`) share a small set of structural
choices that every solver-touching change should respect.

### Probe + executor pattern

Every operation that mutates a stack splits into two functions: a
**probe** that earns the kind knowledge, and a **custom executor**
that uses that knowledge to build the result without re-validating.

```ts
const newKind = kindAfterAbsorbRight(target, card);
if (newKind === null) return null;        // probe short-circuits
const result = absorbRight(target, card, newKind);  // executor trusts
```

Same pattern across `peel` / `pluck` / `yank` / `steal` / `splitOut`
(each paired with its `canX` predicate via `verbForPosition`),
`kindAfterAbsorbLeft` / `absorbLeft`, and the splice probes /
executors. The probe asks "can I do this, and what would the result
be?" with no allocations on the failure path. The executor assumes
the precondition holds and writes the result trivially.

### Three-bucket extends — earned at the commitment point

`extendsTables(target)` returns three Maps in canonical reading
order (`left`, `right`, `set`), each `(value, suit) → resultKind`.
The three Maps are mutually disjoint — a shape's extension lives in
at most one — and which Maps are populated reflects the target's
commitment shape:

- **run / rb / pair_run / pair_rb** — committed to a run-family
  direction. `left` and `right` populated; `set` empty.
- **set / pair_set** — committed to set, unordered. Only `set`
  populated.
- **singleton** — uncommitted. All three populated; this is the
  only kind where a single card can land in any of three modes.

Built once per absorber, at the moment the BFS commits to iterating
that absorber against many sources. The hot path consumes lookups,
not probe calls.

### Iteration order is canon

The BFS produces deterministic plan-line output that depends on
iteration order in the move generator. The DSL conformance fixtures
pin it. **Don't rearrange for readability.** Two orders coexist on
purpose:

- **Action order** is `right → left → set`. Right is the natural
  human-first action; set is the unordered third mode that emits
  both side descriptors per entry.
- **Data layout** is `(left, right, set)` (reading order). Data is
  read left-to-right; actions execute right-first.

Within each shape, iteration is over the sorted union of all
extending shapes per absorber.

### Performance vocabulary

- **Dead card** — fails the live-singleton filter outright (no
  valid 3-card group exists in the accessible pool). Rejected in
  O(1) before BFS starts.
- **Tantalizing card** — passes the liveness filter (a valid group
  *theoretically* exists using accessible cards) but has no actual
  BFS solution. The engine climbs through many states before the
  plateau fires and confirms no_plan. Tantalizing cards drive
  worst-case wall.
  Example: `2C:1` on the Game 17 board — its set partners `2H:0`
  and `2S:0` exist but are locked inside two helper runs whose
  dismantling cannot be repaired.

## Pointers

- `claude-steve/random234.md` — the kitchen-table algorithm spec.
- `claude-steve/random235.md` — corpus_sid_130 walked through step
  by step.
- `claude-steve/random237.md` — the manager-with-budget framing →
  A* derivation.
- `claude-steve/random238.md` — pair-doom memo design (deferred).

## Memory pointers

- `memory/project_stunning_puzzle.md` — STUNNING_PUZZLE state D
  (the puzzle that drove much of this work).
- `memory/feedback_earn_and_use_knowledge.md` — the doctrine
  behind the probe+executor and three-bucket-extends shapes.
- `memory/feedback_iteration_order_is_canon.md` — why the BFS
  iteration order is treated as cross-language canon.
- `memory/feedback_no_side_parameter.md` — the discipline that
  splits left/right into separate functions instead of taking a
  side parameter.
