# engine_v2 — kitchen-table A* solver

The TS solver — best-first search by `f = plan_length +
trouble heuristic`, not depth-first BFS. Boundary interface:
`Buckets in, PlanLine[] | null out`. Used by every TS-side
caller — `agent_player.ts`, `hand_play.ts`, the conformance
suite — and by the Elm UI via the `LynRummyEngine` browser
bundle.

## What it is

A* priority-queue search built around the kitchen-table
algorithm:

- The trouble queue is the unit of progress.
- Each state ranked by `f = plan_length + heuristic(buckets)`.
- Heuristic: `ceil(trouble_debt / 2)` (admissible — each move
  retires at most 2 cards).
- Closed list (state-sig dedup) prevents revisiting equivalent
  states reached via different orderings.

The leaf verb library (`peel`, `pluck`, `yank`, `steal`,
`split_out`, `decompose`, `classifyStack`) is reused unchanged
from `classified_card_stack.ts`. The engine composes it.

## Steal-from-partial

`canSteal` and `steal` operate on length-2 trouble partials in
addition to length-3 helpers. The "steal-from-partial" move
corresponds to the kitchen-table single-motion act of "I grab
the AS from `[AS 2S]` and absorb it onto `[AC' AD]`; the
leftover 2S becomes a singleton." Without this, the engine
would have to model that as a two-step decompose-then-pull,
breaking natural 4-step solutions into 5 awkward steps. See
`claude-steve/random234.md` and `random238.md` for the
reasoning.

## Files

- `src/engine_v2.ts` — engine + heuristics + min-heap.
- `src/buckets.ts` — `fastStateSig` / `buildCardOrder` for
  position-indexed dedup keys (~1.2× faster than a
  string-based sig at the same dedup decisions).
- `bench/check_baseline_timing.ts` — 81-card timing
  regression check (the standing perf gate).
- `bench/gen_baseline_board.ts` — regenerates the gold after
  a deliberate solver change.
- `bench/end_of_deck_perf.ts` — full-game perf harness; runs
  the standing seeds to deck-low.
- `bench/perf_harness.ts`, `bench/budget_sweep.ts`,
  `bench/bench_timing.ts` — auxiliary measurement drivers.
- `bench/bench_outer_shell.ts` — singleton-only vs full
  outer-shell mode comparison on a fixed 60-hand corpus; has
  its own gold (`bench/bench_outer_shell_gold.txt`).

## Optimization levers

| Lever | Effect | Status |
|---|---|---|
| **A* + admissible heuristic** | ~5–8× fewer visits than depth-only iterative deepening | landed |
| **State-sig dedup (closed list)** | ~22% on hard scenarios | landed |
| **Position-indexed `fastStateSig`** | ~1.2× faster than string-sig, same dedup decisions | landed |
| **Card-tracker liveness pruning** | dead-singleton filter at root + per-state singleton-doom | landed |
| Pair-doom memo | est. 5–15% wall (likely smaller) | deferred — see `random238.md` |
| Beam search / Kasparov pruning | est. 5–10× but loses optimality | not pursued |
| Doomed-singleton predicate | catch root-state futility cheaply | deferred |

Heuristic tuning explored five admissible variants;
`half_debt` is the default (the spread between admissible
variants is < 5% on the corpus).

## Practical framing for shipping

For the hint feature:
- **Instant hints (≤3-step plans):** sub-millisecond.
- **Thinking hints (4-5 step plans):** 50–600ms typical. UI
  shows "Thinking…".
- **No plan:** engine returns null after exhausting the
  budget (default 50000 visits ≈ 5–10s worst case). UI shows
  "No hint."

Hint paths cap plan length at 4 (`HINT_MAX_PLAN_LENGTH` in
`hand_play.ts`); `solveStateWithDescs` itself stays complete
for proof-of-no-plan / conformance work.

## Unexplored, in priority order

1. **Beam search** atop A*. Cap queue size to ~100; evict bad
   states. Trades optimality for big-O speedup. Real-game use
   case if speed matters more than minimality.
2. **Singleton-doom predicate.** At root, prove "this trouble
   singleton has no constructible length-3 group anywhere";
   QUIT instantly. Inexpensive check, would make pure no_plan
   cases sub-millisecond.
3. **Pair-doom memo.** Cache per-pair completion-shape work
   across branches. Small win.
4. **Coroutine-scheduled candidate exploration** —
   `claude-steve/random236.md`. Niche.

## Solver design principles

The engine, the verb library (`classified_card_stack.ts`), and
the move generator (`enumerator.ts`) share a small set of
structural choices that every solver-touching change should
respect.

### Probe + executor pattern

Every operation that mutates a stack splits into two
functions: a **probe** that earns the kind knowledge, and a
**custom executor** that uses that knowledge to build the
result without re-validating.

```ts
const newKind = kindAfterAbsorbRight(target, card);
if (newKind === null) return null;        // probe short-circuits
const result = absorbRight(target, card, newKind);  // executor trusts
```

Same pattern across `peel` / `pluck` / `yank` / `steal` /
`splitOut` (each paired with its `canX` predicate via
`verbForPosition`), `kindAfterAbsorbLeft` / `absorbLeft`, and
the splice probes / executors. The probe asks "can I do this,
and what would the result be?" with no allocations on the
failure path. The executor assumes the precondition holds and
writes the result trivially.

### Three-bucket extends — earned at the commitment point

`extendsTables(target)` returns three Maps in canonical
reading order (`left`, `right`, `set`), each
`(value, suit) → resultKind`. The Maps are mutually disjoint
— a shape's extension lives in at most one — and which Maps
are populated reflects the target's commitment shape:

- **run / rb / pair_run / pair_rb** — committed to a
  run-family direction. `left` and `right` populated; `set`
  empty.
- **set / pair_set** — committed to set, unordered. Only
  `set` populated.
- **singleton** — uncommitted. All three populated; this is
  the only kind where a single card can land in any of three
  modes.

Built once per absorber, at the moment the BFS commits to
iterating that absorber against many sources. The hot path
consumes lookups, not probe calls.

### Iteration order is canon

The BFS produces deterministic plan-line output that depends
on iteration order in the move generator. The DSL conformance
fixtures pin it. **Don't rearrange for readability.** Two
orders coexist on purpose:

- **Action order** is `right → left → set`. Right is the
  natural human-first action; set is the unordered third mode
  that emits both side descriptors per entry.
- **Data layout** is `(left, right, set)` (reading order).
  Data is read left-to-right; actions execute right-first.

Within each shape, iteration is over the sorted union of all
extending shapes per absorber.

### Performance vocabulary

- **Dead card** — fails the live-singleton filter outright
  (no valid 3-card group exists in the accessible pool).
  Rejected in O(1) before BFS starts.
- **Tantalizing card** — passes the liveness filter (a valid
  group *theoretically* exists using accessible cards) but
  has no actual BFS solution. The engine climbs through many
  states before the plateau fires and confirms no_plan.
  Tantalizing cards drive worst-case wall.
  Example: `2C:1` on the Game 17 board — its set partners
  `2H:0` and `2S:0` exist but are locked inside two helper
  runs whose dismantling cannot be repaired.

## Pointers

- `claude-steve/random234.md` — the kitchen-table algorithm
  spec.
- `claude-steve/random235.md` — `corpus_sid_130` walked
  through step by step.
- `claude-steve/random237.md` — manager-with-budget framing →
  A* derivation.
- `claude-steve/random238.md` — pair-doom memo design
  (deferred).

## Memory pointers

- `memory/feedback_earn_and_use_knowledge.md` — doctrine
  behind probe+executor and three-bucket-extends.
- `memory/feedback_iteration_order_is_canon.md` — why
  iteration order is treated as cross-language canon.
- `memory/feedback_no_side_parameter.md` — splits left/right
  into separate functions instead of taking a side parameter.
