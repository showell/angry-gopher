# Physical planning — the agent's gesture layer

**Status (2026-05-04):** v2 landed — one-loop architecture with honest
state. Three behavior rules (R1, R2, R3) all enforced inline in the
verb-emission helpers. The legacy lift / fake-state / global geometry-
sweep pipeline retired.

**As of:** 2026-05-04.

---

## What this layer is

The solver (`src/engine_v2.ts`) plans at the *logical* level: which
verbs retire which trouble. It is silent about geometry, hand vs.
board, and which stack physically moves when two combine.

The physical-planning layer (`src/physical_plan.ts` + the helpers in
`src/verbs.ts`) is the bridge from one solver plan to a wire-ready
`Primitive[]`: the sequence of `place_hand` / `merge_hand` /
`merge_stack` / `split` / `move_stack` actions a UI can replay
verbatim. It is the only layer that knows about:

- Where each card is (board location, hand index).
- Which physical motion realizes a logical merge.
- How to keep stacks legal-threshold-clear without surprising the eye.

There is **one** physical-execution pass per play. Honest state
throughout: `sim` is the real board, `pendingHand` is the cards still
in the hand. The verb-emission helpers consult both and pick the
right primitive directly.

---

## The three rules

### R1 — Hand cards play directly toward stacks

A hand card never appears as a transient board singleton when an
existing stack can absorb it. Concretely:

- A hand card whose end-state is "absorbed into stack S" is dragged
  from the hand directly to S via `merge_hand`. The legacy "land as
  singleton, then merge" path is no longer emitted for this case.
- The solver's vocabulary is absorber-active (`free_pull{loose=L,
  target=T}` reads "L pulls toward T"). The gesture vocabulary is
  dragged-piece-active. The translation hides the asymmetry: when the
  solver names a hand card as the *target* of an `extract_absorb`,
  the physical primitive is `merge_hand(handCard → other-stack,
  flipSide(side))` — same physical motion, mirrored grammar. See the
  shared invariant comment above `applyMergeStack` in
  `src/primitives.ts`.

Multi-card placements (a graduate set/run played from hand, or a
multi-card stack a verb consumes) are seeded as a `place_hand` +
`merge_hand` chain at a clean loc before the verb loop runs.

Enforcement: `planMerge` in `src/verbs.ts` consults `pendingHand` at
each merge emission. Multi-placement seeding happens at the top of
`physicalPlan` in `src/physical_plan.ts`.

### R2 — Merges run small-toward-large

When a merge could go either direction (both stacks could physically
host the merged result), the *smaller* stack is dragged onto the
*larger*. Kitchen-table physics: humans grab the lighter pile, and
the heavier pile is more likely to already have room.

Enforcement: `planMerge` swaps source ↔ target and flips side when
`source.length > target.length`. The merged card order is invariant
under the swap (see `applyMergeStack` invariant).

### R3 — Don't move if there's already room

A merge primitive (`merge_stack`, `merge_hand`) produces a stack
larger than either input. Before emitting a `move_stack` pre-flight,
the planner applies the merge to a probe sim and runs `findCrowding`.
If the post-merge board is comfortably clean (no out-of-bounds, no
`PLANNING_MARGIN`-padded overlap), the merge emits in place — no
`move_stack`. Only when the probe shows actual crowding does the
planner relocate the target.

Interior splits remain pre-flighted unconditionally (per Steve,
2026-04-23): siblings of an interior split need a 4-side-clear region
for downstream primitives to build on, even when the immediate
post-board doesn't yet overlap.

Enforcement: `planMergeHand`, `planMergeStackOnBoard`, and the
end-split branch of `planSplitAfter` in `src/verbs.ts`. The trigger
threshold is `findCrowding` (`PLANNING_MARGIN = 15` — between the
legal `BOARD_MARGIN = 7` and the human-feel `PACK_GAP = 30`), NOT the
strict legal-overlap check. `findOpenLoc` still uses `PACK_GAP` for
picking *new* loc slots — that's a separate concern (preferred
spacing for
fresh placements).

---

## Architecture — one loop, honest state

```
solver (engine_v2) ─→ {placements, planDescs}
                                 │
                                 ▼
              physicalPlan(initialBoard, hand, planDescs)
                                 │
                                 ▼
                        Primitive[]  ─→  wire / transcript
```

Inside `physicalPlan` (`src/physical_plan.ts`):

1. **Multi-placement seed** — when `hand.length >= 2`, lay the hand
   cards down as a single growing stack at a clean loc (`place_hand`
   of c0, `merge_hand` of c1..cN). This is the kitchen-table action
   of "lay these together first." Single-placement turns skip the
   seed.
2. **Verb loop** — for each desc in `planDescs`, call `expandVerb(desc,
   sim, pendingHand)`. The verb-emission helpers consult sim and
   pendingHand, picking `merge_hand` vs `merge_stack`, swapping for
   small→large, and pre-flighting only when needed. Apply each
   emitted primitive to sim; remove consumed hand cards from
   `pendingHand`.
3. **Hard-fail** — if `pendingHand` is non-empty after the loop, the
   solver returned placements that no verb references and that we
   didn't seed. That's broken state, not a paper-over case; throw.

`expandVerb` and the per-verb functions in `src/verbs.ts` describe the
verb's structure (which splits, which merges, in what order). The
helpers `planMerge`, `planMergeHand`, `planMergeStackOnBoard`, and
`planSplitAfter` make the physical decisions per emitted primitive.

---

## Files

- `src/physical_plan.ts` — the loop. Multi-placement seed + verb walk
  + hard-fail.
- `src/verbs.ts` — `expandVerb` (hand-aware) + the per-verb structure
  functions + the primitive-emission helpers (R1/R2/R3 inline).
- `src/primitives.ts` — primitive types, `applyLocally`, and the
  shared `applyMergeStack` / `applyMergeHand` card-order invariant.
- `src/geometry.ts` — geometry constants, `findOpenLoc`,
  `findViolation` (legal-threshold strict overlap), and
  `findCrowding` (pre-flight comfort threshold,
  `PLANNING_MARGIN = 15`).
- `src/transcript.ts` — production caller of `physicalPlan`.
  Asserts `findViolation == null` after every emitted
  primitive.

The previous top-level pre-flight sweep retired with v2;
the per-primitive pre-flight logic moved into the
`verbs.ts` helpers, which call it inline at emission time.

---

## DSL fixtures + per-step overlap checks

- `conformance/scenarios/verb_to_primitives_corpus.dsl` (94 scenarios,
  auto-converted) and `verb_to_primitives.dsl` (8 hand-authored)
  exercise per-verb expansion via `moveToPrimitives` (which calls
  `expandVerb` with empty `pendingHand`).
- `conformance/scenarios/physical_plan_corpus.dsl` exercises the
  integration layer — `physicalPlan` with hand cards + multi-verb
  plans, including R1/R3 cases.
- All three runners assert `findViolation == null` after every
  emitted primitive, not just at the end. A primitive that creates an
  overlap fails the moment it appears.

---

## Related docs

- `ENGINE_V2.md` — what the solver hands to this layer.
- `../ARCHITECTURE.md` — repo-level layering and the gesture pipeline.
- `claude-steve/random249.md`, `random250.md`, `random253.md` —
  design-conversation predecessors (frozen essays).
