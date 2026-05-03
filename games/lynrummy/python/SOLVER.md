# SOLVER.md — Lyn Rummy BFS planner

> **READ THIS FIRST if your work touches the BFS solver.** The solver
> is the #1 active asset of the Python codebase. The Elm UI is
> largely self-sufficient at this point; the solver is where active
> algorithmic development happens, and it's where regressions are
> most expensive. Sub-agents dispatched to do solver work must be
> told to read this file. README.md is the front door; SOLVER.md is
> the workshop floor.
>
> **The Python solver has a sibling.** A TypeScript port of the
> engine lives at `../ts/` and matches Python plan-line-for-plan-line
> via the DSL conformance suite (run `npm test` in `../ts/` to
> verify). Python remains the experimentation surface (this doc);
> the TS engine will replace the Elm BFS in the browser. See
> [`../ts/README.md`](../ts/README.md). The Elm BFS (`Game.Agent.*`)
> is on life-support — drifting from Python, kept alive only until
> TS integration lands.

The solver lives in five modules:

  - `bfs.py` — the search engine.
  - `enumerator.py` — the move generator.
  - `classified_card_stack.py` — the data type + verb library.
  - `move.py` — descriptor types + plan-line rendering.
  - `buckets.py` — 4-bucket state shape + boundary helper.

Plus a small accelerator at `card_neighbors.py`. Benchmark
harness lives in TS at `../ts/bench/bench_timing.ts`.

## Core principle: earn knowledge, use earned knowledge

Every computation in the solver should EARN knowledge that the rest
of the algorithm uses, and every hot-loop operation should CONSUME
already-earned knowledge instead of re-deriving it. When you find
yourself dispatching on `kind` in a hot inner loop, or
re-classifying a stack you already classified upstream, or
boundary-checking the same target against many cards, the question
is not "how do I make this branch faster?" It's "why doesn't the
data already know?"

The corollary that's easy to get wrong:

  - **Earned knowledge** = a fact the algorithm has *already
    established* through prior steps that committed to using it.
    Storing it is making available something *already there for
    the taking*.
  - **Speculation** = trying something to find out whether knowledge
    is worth earning. Speculation is essential — it's the mechanism
    by which knowledge gets earned. It only goes wrong when we
    commit to a speculative shape before it's been proven.

Speculative pre-computation is the most common solver bug: building
caches or tables on every instance of a data type when most
instances are never queried. That's not earned, just reserved on
spec. Push the work to the COMMITMENT POINT — the place in the
algorithm that's already decided to use the result many times.

See `memory/feedback_earn_and_use_knowledge.md` for the lesson with
its receipts.

## Data shape

### `ClassifiedCardStack` (CCS) — what BFS uses internally

Every stack inside the BFS is a `ClassifiedCardStack`. Three slot
reads cover every access:

  - `stack.cards` — tuple of `(value, suit, deck)` triples.
  - `stack.kind` — one of seven: `run` / `rb` / `set` / `pair_run`
    / `pair_rb` / `pair_set` / `singleton`. NO `KIND_OTHER`.
  - `stack.n` — cached length.

The earned absorb tables (`extends_left`, `extends_right`,
`set_extenders`) are *not* fields on the stack — they're the
return value of the module-level `extends_tables(stack)` function,
computed on demand. See "Three-bucket extends" below.

There are NO dunder methods. `len(stack)`, `for c in stack`, `stack[i]`
all raise. This is intentional:

1. **Speed**: dunder dispatch is slow on the hot path; slot reads
   of named fields are direct attribute hits.
2. **Elm portability**: the Elm port has no equivalent of `__iter__`
   / `__getitem__` / `__len__` — every access goes through record
   fields. Mirroring that here makes the (deferred) Elm/TS port a
   near-mechanical translation.

### The boundary classifies once

`solve_state_with_descs` calls `classify_buckets`, which converts a
raw input `Buckets` of card-list stacks into a `Buckets` of CCS.
Any stack that fails to classify into one of the seven kinds raises
`ValueError`. That's a caller bug, not a BFS bug. The "no
KIND_OTHER" invariant holds inside the BFS by construction;
downstream code consumes `stack.kind` directly.

### Probes earn the kind; executors consume it

The pattern across every operation that mutates a stack:

```python
new_kind = kind_after_absorb_right(target, card)
if new_kind is None:
    return None
result = absorb_right(target, card, new_kind)
```

The probe asks "can I do this, and what would the result be?" and
short-circuits on failure with no allocations. The executor assumes
the precondition holds and builds the result without re-validating.

Same pattern for the splice probe + executor and for the
source-side verbs (`peel` / `pluck` / `yank` / `steal` /
`split_out`, each paired with a `can_X` predicate). The verb
executors derive remnant kinds from the parent's kind family +
length — no full reclassification.

### Splice — run/rb-only and same-value-matched

Splice is the BFS move that inserts a TROUBLE singleton into a
length-4+ HELPER run/rb such that both halves remain length-3+
legal groups. The contract is **run/rb-only**: set parents extend
via the absorb operation (the `set_extenders` bucket on the
absorber); a "set splice" is a misnomer that produces zero
BFS-useful moves and the splice probes raise on non-run/rb parents.

The earned-knowledge accelerator is `find_splice_candidates(parent,
card)` — a **same-value-match scan** that emits exactly the (side,
position) pairs where a splice yields two length-3+ family-kind
halves. The proof, in one paragraph: every BFS-useful splice forces
the inserted card's value to equal some parent[m]'s value (the
boundary check on the with-card half collapses to that). So the
candidate set is enumerable in one walk of `parent.cards` looking
for value matches; per match at index m, two candidates fire —
`left@m` and `right@(m+1)` — provided `m ∈ [2, n-3]` and the
per-family compatibility check passes:

  - **rb parent**: card must match parent[m]'s color.
  - **run parent**: card must match parent[m]'s suit (the cross-deck
    case in practice — same value+suit across decks is the only
    realistic way to hit it).

Each emitted candidate is guaranteed valid; no probe call is needed
in the BFS hot path. This is the human pattern: a player scanning
for splice opportunities looks for a same-value match in a helper
run, not for every interior position. The data structure now
matches the way the algorithm is naturally explored.

The probes (`kinds_after_splice_left/_right`) remain available for
generic callers (tests, the leaf DSL conformance suite). The BFS
hot path consumes `find_splice_candidates` directly.

### Three-bucket extends — earned knowledge at the commitment point

Each absorber stack carries three precomputed dicts in canonical
**reading order** (`left, right, set`):

  - `left_extenders`: `{(value, suit) → result_kind}` for cards that
    legally absorb on the left edge.
  - `right_extenders`: same for the right edge.
  - `set_extenders`: same for set-mode absorbs (sets are unordered
    so both sides accept these shapes).

The three dicts are mutually disjoint — a card's shape lives in at
most one of them. They encode the target's commitment shape:

  - **run / rb / pair_run / pair_rb** (committed to a run-family
    direction): `left` and `right` populated; `set` empty.
  - **set / pair_set** (committed to set, unordered): only `set`
    populated.
  - **singleton** (uncommitted): all three populated. Singletons
    are the only kind where a single card can land in any of three
    modes.

Built ONCE per absorber, in `_build_absorber_shapes`, at the moment
the BFS commits to iterating an absorber against many sources. The
hot-path callers iterate the sorted union of shapes per absorber;
every entry guarantees a legal absorb in one of the three modes.
No per-card probe call.

This is the canonical "earned knowledge at the commitment point"
pattern. An earlier attempt put extends tables on every CCS at
construction — that was speculative (most CCSs are never probed
as absorbers) and lost the trade-off. The fix was pushing the work
to where commitment exists.

## Don't manufacture symmetry — left and right are different operations

Left and right look symmetric on the surface but are not. **Never
pass `side` as a parameter** to a function in the solver. If you
find yourself writing `if side == "left": ... else: ...`, split
the function into `_left` and `_right` variants and let each one
do its own job. The branching doesn't go away when you parameterize
— it moves into the helper, where the caller's commitment to "I'm
handling the right edge" is lost.

Concrete examples that already exist in the code:

  - `kind_after_absorb_right` / `kind_after_absorb_left` — separate
    probes, no `side` arg.
  - `absorb_right` / `absorb_left` — separate executors.
  - `_absorb_seq_right` / `_absorb_seq_left` — separate sequential
    absorb primitives for push/engulf.
  - `splice_left` / `splice_right`, `kinds_after_splice_left` /
    `kinds_after_splice_right`, `_splice_halves_left` /
    `_splice_halves_right`, `_kinds_after_splice_run_left` /
    `_kinds_after_splice_run_right`.

The pattern: action verbs and their probes get split per side;
data layout (the three-bucket extends, descriptor `side` field)
stays unified because it's data, not action.

For sets specifically: sets are *truly* symmetric (unordered), so
they get a single `set_extenders` bucket and yield both right and
left descriptors per entry to preserve plan-output. They're not
"left or right"; they're an unordered third mode.

See `memory/feedback_no_side_parameter.md`.

## Iteration order is the cross-language canon

The BFS produces deterministic plan-line output that depends on
iteration order in the move-generator callers. The DSL conformance
fixtures pin the canonical iteration order; Python, the Elm BFS,
and the TS engine all match plan-line-for-plan-line.

**Don't change Python iteration order without porting in lockstep.**
The TS engine is the durable target (148/148 cross-check); the Elm
BFS is on life-support but still in production until TS integration
lands.

The current canon:

  - **Iterate the sorted union** of all extending shapes per absorber.
    Within each shape, action order is **right → left → set** (right
    is the natural human-first action; set is the unordered case
    yielding both side descriptors).
  - **Data layout** is `(left, right, set)` (reading order). The
    action order and the data-layout order are different on purpose:
    data is read left-to-right; actions execute right-first.

After the Elm BFS is retired and TS is the only sibling, the
iteration order can be cleaned up (e.g., per-bucket iteration is
cleaner but reorders plan lines). Until then, leave it alone.

See `memory/feedback_iteration_order_is_canon.md`.

## Hint projection — how `find_play` uses BFS for hand cards

`agent_prelude.find_play(hand, board)` is the hand-aware outer
loop. It returns:

```python
{"placements": [card, ...], "plan": [(line, desc), ...]}
```

or `None` if no play was found.

**Search order** (encodes game preference; no scoring):

  - **(a) Pairs with a completing third in hand** — three cards
    leave the hand in one move, no BFS needed. Tried first across
    all meldable pairs (`rules.is_partial_ok([c1, c2])` predicate).
  - **(b) Pairs without a third** — project the pair as a 2-card
    trouble stack onto the board, run BFS. First pair that yields
    a plan returns.
  - **(c) Singletons** — project each remaining card as a 1-card
    trouble stack onto the board, run BFS. First card that yields
    a plan returns.
  - **(d) Nothing fired** — return `None`.

**The dirty-board constraint** (`_try_projection`):

When projecting a candidate (singleton or pair) onto the board,
BFS must clear **all** trouble — not just the newly placed cards.
The augmented board is `board + extra_stacks`; classify every
stack; HELPER stacks pass through; everything else (pre-existing
partials AND the newly placed cards) goes into TROUBLE; BFS gets
`(helper, trouble, [], [])` and must produce a plan that resolves
the entire trouble bucket. If it can't, the placement is rejected.

This is the core constraint: projecting onto a board that already
has 2 trouble stacks means BFS must clean all 3 in one plan. The
agent is not allowed to leave the board dirtier than it found it.

**Renderer:** `format_hint(result)` wraps `find_play`'s return into
a `[str]` step list with the placement step explicit ("place [JD:1
QD:1] from hand"), suitable for direct display or DSL serialization.
Conformance scenarios live in `conformance/scenarios/hint_game_seed42.dsl`.

The TS port will eventually mirror this surface. The key invariant
that any reimplementation must preserve: **the classifier and the
BFS engine must agree on what "trouble" means** — same classify
logic, same BFS state machine. If those diverge, hint results
won't match across implementations.

## Module map

### `bfs.py` — search engine

  - `bfs_with_cap` — pure BFS by program length, bounded by max
    trouble count.
  - `solve_state_with_descs` — outer iterative-deepening loop;
    the canonical entry point.
  - `solve_state` / `solve` — thin wrappers.
  - Boundary: `solve_state_with_descs` calls `classify_buckets`,
    promoting raw input to CCS once at entry. The "no KIND_OTHER"
    invariant holds for everything downstream.
  - Doomed-singleton filters via `card_neighbors.py`.

### `enumerator.py` — move generator dispatcher

`enumerate_moves(state)` is a 25-line dispatcher; each move type
has its own focused helper:

  - `_yield_extract_absorbs` — extract-then-absorb (move type a).
  - `_yield_free_pulls` — TROUBLE singleton onto absorber (a').
  - `_yield_shifts` — shift moves (d).
  - `_yield_splices` — splice moves (c).
  - `_yield_pushes` — push TROUBLE onto HELPER (b).
  - `_yield_engulfs` — GROWING engulfs HELPER (b').

Plus the precomputation phase: `_build_absorber_shapes` (earns the
three-bucket extends per absorber), `_eligible_splice_helpers`,
`_eligible_shift_helpers`, `extractable_index`.

### `classified_card_stack.py` — CCS data type + verb library

  - The `ClassifiedCardStack` dataclass.
  - 7-kind alphabet (`KIND_RUN` etc.) and family helpers.
  - `classify_stack` — the rigorous classifier (boundary use only).
  - `extends_tables` — earned-knowledge constructor for absorbers.
  - Source-side verbs: `peel` / `pluck` / `yank` / `steal` /
    `split_out` plus their `can_X` predicates.
  - Target-side absorb: `kind_after_absorb_right/left` probes +
    `absorb_right/left` executors.
  - Splice: `kinds_after_splice_left/right` probes + `splice_left/
    right` executors (run/rb only — see "Splice" section above).
  - `find_splice_candidates` — same-value-match accelerator;
    consumed directly by `_yield_splices` in the enumerator.

Most BFS hot-path arithmetic lives here.

### `move.py` — descriptor types + plan rendering

`ExtractAbsorbDesc` / `FreePullDesc` / `PushDesc` / `ShiftDesc` /
`SpliceDesc` carry raw card tuples / lists, NOT CCS objects, for
plan-line stability and downstream serialization. `describe`,
`narrate`, `hint` render plans for various consumers.

### `buckets.py` — state shape + boundary

`Buckets` (4-bucket NamedTuple), `FocusedState`, `state_sig`,
`trouble_count`, `is_victory`, and `classify_buckets` — the
boundary helper that converts raw input to CCS-shaped state.

### `card_neighbors.py` — liveness accelerator

104-element `card_loc` bucket-tag array + precomputed `NEIGHBORS`
partner-pair table. O(72) liveness queries instead of O(pool²)
classify scans. See [BFS_CARD_TRACKER.md](BFS_CARD_TRACKER.md).

## Validation methodology — gates for every solver-touching change

Run **all five** gates after any change touching `bfs.py` /
`enumerator.py` / `move.py` / `classified_card_stack.py` /
`buckets.py` / `rules/` or the `verbs.py` / `primitives.py` /
`agent_prelude.py` layers. No exceptions; the cost of a missed
regression in this part of the codebase is high.

### 1. Unit + conformance suite

```
./check.sh
```

Runs every `test_*.py` in the python directory. Exits non-zero on
any failure (either non-zero exit code OR an inline `FAIL`
marker). Tests aren't load-bearing without enforcement; this
script IS the enforcement.

### 2. DSL cross-language conformance

```
ops/check-conformance
```

Runs `cmd/fixturegen` to compile DSL → fixtures, then Python
conformance, then the Elm test suite. Catches Python/Elm
divergence on plan-line output. **The Elm BFS is the active
production code; iteration-order changes that break the Elm side
must be coordinated, not committed unilaterally.**

### 3. Baseline timing check

```
cd ../ts && npm run bench:check-baseline
```

Measures all 81 baseline scenarios under `ts/bench/bench_timing.ts`
(warmup + min-of-20). Compares against the gold at
`ts/bench/baseline_board_81_gold.txt`. Flags any scenario whose
time exceeds gold by more than the tolerance (default 10%) AND
whose gold itself is above the noise floor (50ms in TS — adjusted
down from Python's 200ms because TS solves the corpus ~4× faster).

### 4. Outer-shell benchmark

```
cd ../ts && npm run bench:outer-shell
diff <(npm run --silent bench:outer-shell) bench/bench_outer_shell_gold.txt
```

Compares singleton-only vs. full (triple + pair + singleton)
across the fixed 60×6-card corpus. Plan quality must stay
`better=18 same=42 worse=0`. A regression is full *both* slower
*and* lower plan quality.

### 5. Offline self-play smoke

```
python3 agent_game.py --offline --max-actions 200
```

Should finish in <10s with at least a few plays completed. Catches
"BFS hangs" or "agent stuck" failures that gates 1-4 might miss.

## Bench gold files

Two gold files live in `../ts/bench/`:

  - `baseline_board_81_gold.txt` — 81-card baseline (one trouble
    singleton per remaining card on the Game 17 board). Line-
    oriented, sorted by id. The most precise per-scenario regression
    detector.
  - `bench_outer_shell_gold.txt` — outer-shell benchmark output.

**Naming convention:** every benchmark gets a gold file named
`<bench_name>_gold.txt`. Plain text. Diff-friendly. Sortable.

### Capture process

The 81-card gold uses a deliberately careful capture process to
reduce between-capture variance:

```
cd ../ts && npm run bench:gen-baseline
```

Internally, this:

1. Runs a **pre-suite warmup pass** (all 81 scenarios untimed)
   so subsequent timing isn't biased by JIT cold-start.
2. Then measures each scenario via `bench_timing.timeSolver`
   (warmup + min-of-20). Pass `--expose-gc` to Node for tighter
   timings.
3. Writes the gold.

Even with that discipline, between-capture variance is real —
~5-10% on the hot scenarios depending on system thermal state and
load. **Refresh gold only when you believe you've earned a clear
win.** When you do, capture two or three times and confirm the
numbers are stable before committing.

### Regenerate after solver changes

```
cd ../ts
npm run bench:gen-baseline
ops/check-conformance       # regenerate DSL fixtures (run from repo root)
npm run bench:check-baseline
```

Then commit both `baseline_board_81.dsl` and
`ts/bench/baseline_board_81_gold.txt`.

## BFS performance vocabulary

**Tantalizing card** — a hand card that passes the
`_all_trouble_singletons_live` filter (a valid group using board
cards theoretically exists) but has no actual BFS solution. BFS
climbs through many cap levels before the plateau fires and
confirms `no_plan`. Tantalizing cards drive worst-case timing;
their apparent neighbors are locked inside helper stacks whose
dismantling causes cascading partials.

Example: `2C:1` on the Game 17 board. Its set partners `2H:0`
and `2S:0` exist on the board but are locked inside two separate
runs; freeing either one breaks a helper that cannot be repaired.

**Dead card** — fails the live-singleton filter outright (no
valid 3-card group exists in the pool). Rejected in O(1) before
BFS starts.

**Card-tracker accelerator** — `card_neighbors.py`'s `card_loc`
+ `NEIGHBORS`. Used at two BFS sites: the static pre-BFS
dead-singleton filter and a dynamic per-state prune gated on
group-completion events. See
[BFS_CARD_TRACKER.md](BFS_CARD_TRACKER.md).

## TypeScript sibling — landed v1; engine_v2 added 2026-05-02

The TS engine at `../ts/` is the next-gen browser BFS. Status:

  - **Leaves**: complete. Full DSL conformance passes.
  - **Engine v1 (`bfs.ts`)**: complete. Plan-line-for-plan-line
    cross-check vs Python via the DSL conformance contract.
  - **Engine v2 (`engine_v2.ts`)**: A* priority queue + closed
    list, drop-in alternative to v1. Validated on 116 conformance
    scenarios (46 easy + 70 medium); zero regressions. Adds
    `decompose` verb + steal-from-partial vocab. See
    `../ts/ENGINE_V2.md`. Not yet the production path.
  - **Card-tracker liveness accelerator**: not yet ported.
    Correctness is unaffected; perf on tantalizing-card scenarios
    will lag Python until ported.
  - **Browser integration**: not yet wired.

Run `npm test` in `../ts/` to see live status.

What carries forward verbatim from this doc:

  - 7-kind alphabet, no-KIND_OTHER invariant.
  - Probe + executor pattern.
  - Earned-knowledge structure at the commitment point.
  - The `_left` / `_right` / `_set` separation discipline.
  - The DSL conformance fixtures as the cross-language contract.

When iterating on the algorithm, the Python solver remains the
experimentation surface. Port confirmed-good changes to TS via the
DSL conformance contract. The Elm BFS continues to track Python by
necessity (it's still production) but is on life-support.

## Outstanding TODOs

  - Iteration order cleanup (left → right → set per-bucket
    instead of sorted-union) — deferred until Elm retirement.
  - Multi-capture median for gold (proposal C from
    `random211_bench.md`) — reach for it when locking in a clear
    win.
  - Port `card_neighbors` to TS for liveness-filter parity.
  - Hoist absorb/splice executors out of TS `enumerator.ts` into
    `classified_card_stack.ts` proper (sub-agent kept them local
    in v1).
