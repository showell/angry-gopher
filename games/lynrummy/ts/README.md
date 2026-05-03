# LynRummy — TypeScript BFS engine

**Status:** Two engines coexist. `bfs.ts` (v1) is the production
candidate for browser BFS migration; `engine_v2.ts` (A* alternative)
shipped 2026-05-02 as an experimental drop-in. Browser integration
pending; Python BFS is on life-support.
**As of:** 2026-05-03

> **Working on the BFS solver?** Read
> [`../python/SOLVER.md`](../python/SOLVER.md) FIRST — it documents
> the design principles (earned knowledge, no `side` parameter,
> 7-kind alphabet, iteration order canon), the data shapes, the
> validation methodology, and everything the Python and TS engines
> share. This subtree is the TS half of that story.

## What this is

The LynRummy BFS solver, ported from Python to TypeScript. Same
algorithm, same DSL conformance fixtures, same plan-line outputs —
implemented in TS so the engine can run in the browser via Elm
ports without Elm-runtime overhead on the BFS hot path. The Python
solver remains the experimentation surface; the TS engine mirrors
it leaf-by-leaf via the cross-language DSL contract in
`../conformance/leaf/`.

Behavioral parity with Python was verified by full DSL conformance
plus 25 real games × ~9 `find_play` calls of cross-validation via a
since-retired Python-orchestrated harness. That harness surfaced one
port-fidelity bug the curated corpus didn't catch (TS `successor`
was missing K→A wraparound; commit `651318f` fixed it). The lesson —
*curated fixtures have coverage gaps; real-workload cross-validation
is what closes them* — is captured in
`memory/feedback_corpus_blind_spots.md`.

## Two engines

- **`src/bfs.ts`** (v1) — the iterative BFS port. Plan-line-for-
  plan-line cross-check vs Python via the DSL conformance fixtures.
  This is the engine the browser will call when integration lands.
- **`src/engine_v2.ts`** (added 2026-05-02) — A* priority-queue
  alternative built on the kitchen-table algorithm. Drop-in
  interface with `bfs.ts` (`Buckets` in, `PlanLine[] | null` out).
  Adds `decompose` verb + steal-from-partial vocab. Validated on
  116 conformance scenarios; not yet the production path. See
  [`ENGINE_V2.md`](./ENGINE_V2.md).

## Layout

- `src/rules/card.ts` — Card type, label parser, RANKS / SUITS / RED.
- `src/classified_card_stack.ts` — the data type, kind alphabet,
  leaf primitives. Largest file. Mirrors `python/classified_card_stack.py`.
- `src/buckets.ts` — 4-bucket state shape, `classifyBuckets`
  boundary, state-sig hashing, victory predicates.
- `src/move.ts` — descriptor types + `describe` / `narrate` /
  `hint` plan-line renderers.
- `src/enumerator.ts` — move generator dispatcher + per-move-type
  helpers (extract+absorb, free pull, shift, splice, push, engulf,
  decompose) + focus rule + lineage tracking.
- `src/bfs.ts` — v1 search engine (`bfsWithCap`, `solveStateWithDescs`).
- `src/engine_v2.ts` — A* engine + heuristics + min-heap.
- `src/hand_play.ts` — `find_play` / `format_hint` for hand-aware
  hints. Mirrors `python/agent_prelude.py`.
- `bridge.ts` (top-level, not under `src/`) — single CLI entry
  point (stdin JSON request → stdout JSON response). The
  cross-language interface; called from Python via
  `../python/ts_solver.py` (subprocess per call).
- `test/test_conformance_leaf.ts` — leaf DSL conformance.
- `test/test_engine_conformance.ts` — engine vs JSON fixtures. The
  canonical BFS conformance runner since the Python runner retired
  2026-05-02.
- `bench/` — perf measurement drivers + investigation scripts.

## Running tests

```
node test/test_conformance_leaf.ts     # leaves only
node test/test_engine_conformance.ts   # engine vs JSON fixtures
npm test                               # both
```

Node v24's native TS support runs `.ts` files directly — no compile
step, no `tsx`, no dependencies. The build setup is intentionally
minimal.

## What carries forward from Python (verbatim)

Every design principle in `../python/SOLVER.md` applies here:

- **Earn knowledge, use earned knowledge.** Probes earn the kind;
  executors consume it. `extendsTables` builds the absorber's
  accept tables once at the commitment point.
- **No `side` parameter.** Right and left are different operations;
  pairs of named functions, never a `side` arg.
- **No dunders.** Slot-style interfaces; data is read through
  named fields.
- **Iteration order is canon.** Plan-line output depends on the
  order moves are yielded. The TS engine matches Python bit-for-bit
  (verified by the DSL conformance suite).
- **Splice is run/rb-only.** Set parents extend via the absorb
  operation, not splice; `findSpliceCandidates` uses the
  same-value-match human heuristic.

## State signature hashing

The TS engine uses a packed-int-string strategy for `Set` keys
(JS Sets compare objects by reference, not value). Each card encodes
as `((value*4)+suit)*2+deck` (max 111). Cards are sorted within each
stack and joined with `,`; stacks are sorted lexicographically and
joined with `;`; buckets join with `|`; lineage folds in via `@`.
Decision documented inline in `src/buckets.ts`. `engine_v2.ts` adds
a position-indexed `fastStateSig` (~1.2× faster, same dedup
decisions) — see `src/buckets.ts` `buildCardOrder`.

## Open design surfaces

These aren't deferred features — they're decisions that haven't
been made yet because they'll first matter at browser integration:

- **Cross-language wire format for descriptors.** TS uses camelCase
  (`extCard`, `targetBefore`); Python uses snake_case
  (`ext_card`, `target_before`); Elm has its own. Working
  assumption: snake_case JSON across the wire, TS layer converts at
  one boundary. Tracked as `CROSS_LANG_WIRE_FORMAT` in
  `MINI_PROJECTS.md`. Pin before integration.
- **`isAlreadyClassified` shape-sniff vs typed boundary.**
  `src/bfs.ts:236` inspects the first non-empty bucket's first
  stack to decide whether to classify. Cleaner: take only
  `RawBuckets` at the public entry point and classify always
  (idempotent at caller). Worth pinning before browser integration
  since serialization quirks could hit this surface silently.

## Bench methodology decisions

Notes worth knowing if you're touching `bench/`:

- **PRNG.** TS uses mulberry32 (seedable, native to JS); Python used
  Mersenne Twister. The 60 hands in `bench_outer_shell` differ
  across the two; `bench_outer_shell_gold.txt` is TS-specific.
  Cross-language hand selection wasn't a goal.
- **`MIN_BASELINE_MS = 50`** in `check_baseline_timing.ts` (lowered
  from Python's 200). TS solves the same corpus ~4× faster; the
  lower threshold keeps the regression net useful.
- **Profiling.** No `cProfile` analog. For deep profiling, run TS
  bench under `node --prof` then post-process with
  `node --prof-process`.
- **GC control.** V8 doesn't expose generational-GC toggling like
  CPython. Min-of-N with optional `--expose-gc` is the substitute.

## Naming convention

snake_case is fine here — see
`memory/feedback_snake_case_in_elm.md`. The port stays close to
its Python source, and that's the point. Don't flag snake_case as
a critique target.

## Loose ends

- **Card-tracker liveness pruning** (priority: before browser
  integration). Python has two filters not yet ported:
  `_all_trouble_singletons_live(b)` (called once before BFS in
  `bfs.py:323`) and `_any_trouble_singleton_newly_doomed(b)`
  (called inside the BFS on group-completion events,
  `bfs.py:160-162`). Both backed by `card_neighbors.py`'s
  card-tracker accelerator. v1 conformance corpus is solvable
  boards; runaway-class boards aren't tested. TS BFS will work
  but bloat `seen` and hit `maxStates` cap on hard puzzles
  Python solves cheaply. Bench against `python/corpus/` first to
  size the gap.
- **Splice executors inline in `enumerator.ts`** (priority:
  opportunistic). The probes (`right_splice_candidates`,
  `left_splice_candidates`) live in `classified_card_stack.ts`;
  the executors (`splice_left`, `splice_right`) are inline in
  `enumerator.ts` because the v1 port task explicitly avoided
  touching the leaf module. Ought to move next to the probes; no
  behavior change. (Self-trigger "next time someone touches either
  file" has fired multiple times without action; treat as a real
  TODO, not a heuristic.)
- **Browser integration.** Replace the Elm BFS with this engine
  via Elm ports. The Elm BFS is on life-support — see
  `../elm/README.md` for status. Wire format pinning is the
  prerequisite (see Open design surfaces above).
- **Possibly expand TS to handle hand-to-board interactions**,
  reducing the Elm/TS split surface for the UI. Open question.

## Pointers

- [`../python/SOLVER.md`](../python/SOLVER.md) — design principles,
  data shapes, validation methodology shared with Python.
- [`ENGINE_V2.md`](./ENGINE_V2.md) — engine_v2 reference (status,
  vocab fix, optimization levers, when-to-call-which).
- [`../DOC_AUTHOR_RULES.md`](../DOC_AUTHOR_RULES.md) — read before
  touching docs in this subtree.
- `memory/feedback_corpus_blind_spots.md` — the K→A bug story; why
  cross-validation matters even with green conformance.
