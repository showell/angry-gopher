# LynRummy — TypeScript BFS engine

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
ports without paying Elm-runtime overhead on the BFS hot path.

The Python solver remains the experimentation surface; the TS
engine mirrors it leaf-by-leaf via the cross-language DSL contract
in `../conformance/leaf/`.

## Status

  - **Leaf primitives**: complete. Full DSL conformance passes —
    `classifyStack`, both absorb probes, `extendsTables`, all five
    source verbs (peel / pluck / yank / steal / split_out), both
    splice probes, `findSpliceCandidates` (the same-value-match
    accelerator).
  - **Engine**: complete v1. Plan-line-for-plan-line cross-check
    vs Python via the same DSL conformance fixtures the Python
    solver uses.
  - **Card-tracker liveness accelerator** (`card_neighbors.py` ↔
    `card_neighbors.ts`): not yet ported. Correctness is unaffected;
    perf on tantalizing-card scenarios will lag Python until ported.
  - **Browser integration**: not yet wired. Engine runs under Node
    via `npm test`; Elm port wiring will come when we replace the
    Elm BFS with this engine.

Run `npm test` to see live status.

## Layout

  - `src/rules/card.ts` — Card type + label parser + RANKS / SUITS / RED.
  - `src/classified_card_stack.ts` — the data type, kind alphabet,
    leaf primitives. Largest file. Mirrors `python/classified_card_stack.py`.
  - `src/buckets.ts` — 4-bucket state shape, `classifyBuckets`
    boundary, state signature hashing, victory predicates.
  - `src/move.ts` — descriptor types + `describe` / `narrate` /
    `hint` plan-line renderers.
  - `src/enumerator.ts` — move generator dispatcher + per-move-type
    helpers (extract+absorb, free pull, shift, splice, push, engulf)
    + focus rule + lineage tracking.
  - `src/bfs.ts` — search engine (`bfsWithCap`, `solveStateWithDescs`).
  - `test/test_conformance_leaf.ts` — leaf DSL conformance runner.
  - `test/test_engine_conformance.ts` — engine-level conformance
    against `python/conformance_fixtures.json` (the same fixtures
    Python's `test_dsl_conformance.py` uses).

## Running tests

```
node test/test_conformance_leaf.ts     # leaves only
node test/test_engine_conformance.ts   # engine + cross-check vs Python
npm test                               # both
```

Node v24's native TS support runs `.ts` files directly — no compile
step, no `tsx`, no dependencies. The build setup is intentionally
minimal.

## State signature hashing

The TS engine uses a packed-int-string strategy for `Set` keys
(JS Sets compare objects by reference, not value). Each card encodes
as `((value*4)+suit)*2+deck` (max 111). Cards are sorted within each
stack and joined with `,`; stacks are sorted lexicographically and
joined with `;`; buckets join with `|`; lineage folds in via `@`.
Decision documented inline in `src/buckets.ts`.

## What carries forward from Python

Every design principle in `../python/SOLVER.md` applies here verbatim:

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

## Next steps

1. **Hoist local absorb/splice executors** out of `enumerator.ts`
   into `classified_card_stack.ts` proper (sub-agent kept them local
   in v1 per scope discipline). Plus leaf DSL fixtures for them.
2. **Port `card_neighbors`** for the liveness accelerator.
3. **Browser integration**: replace the Elm BFS with this engine
   via Elm ports. The Elm BFS is on life-support — see
   `../elm/README.md` for status.
4. **Possibly expand TS to handle hand-to-board interactions**,
   reducing the Elm/TS split surface for the UI. Open question.
