# Physical planning — the agent's gesture layer

**Status (2026-05-04):** v1 landed. Single-placement hand-card lift is
live; multi-placement, small→large merges, and "don't move when there's
room" tightening are pending. The doc below describes the *target*
behavior; the **Implementation status** section tracks which target
clauses are honored today vs. open.

**As of:** 2026-05-04.

---

## What this layer is

The solver (`src/engine_v2.ts`) plans at the *logical* level: which
verbs retire which trouble. It is silent about geometry, hand vs.
board, ordering of physical motions, and which stack physically moves
when two combine.

The physical-planning layer (`src/physical_plan.ts` +
`src/geometry_plan.ts`) is the bridge from one solver plan to a wire-
ready `Primitive[]`: the sequence of `place_hand` / `merge_hand` /
`merge_stack` / `split` / `move_stack` actions a UI can replay
verbatim. It is the only layer that knows about:

- Where each card *is* (board location, hand index).
- Which physical motion realizes a logical merge.
- How to keep stacks pack-gap-clear without surprising the eye.

There is **one** physical-execution pass per play. The legacy per-
verb pre-flighting in `moveToPrimitives` is myopic and is no longer
on the production path; it remains as a unit-test surface for the
verb-expansion library.

---

## The three requirements

Each requirement names a target behavior, names what enforces it (or
will), and points at the relevant code paths.

### R1 — Hand cards play directly toward stacks

A hand card never appears as a transient board singleton when an
existing stack can absorb it. Concretely, for every play:

- A hand card whose end-state is "absorbed into stack S" is dragged
  from the hand directly to S via `merge_hand`. The legacy "land as
  singleton, then merge" path is no longer emitted for this case.
- A hand card whose end-state is "first card of a brand-new stack"
  (no pre-existing absorber) lands via `place_hand`. This is the
  unavoidable case.
- The solver's vocabulary is absorber-active (`free_pull{loose=L,
  target=T}` reads "L pulls toward T"). The gesture vocabulary is
  dragged-piece-active. The translation hides the asymmetry: when the
  solver names a hand card as the *target* of an `extract_absorb`,
  the physical primitive is `merge_hand(handCard → other-stack,
  flipSide(side))` — same physical motion, mirrored grammar.

Enforcement: `liftSinglePlacement` in `src/physical_plan.ts`. The
function walks the logical primitive trace, finds the placement's
first downstream consumer, and rewrites `(place_hand P) + (merge_stack
P → S | merge_stack X → P)` as a single `merge_hand`.

### R2 — Merges run small-toward-large

When a `merge_stack` could go either direction (both stacks could
physically host the merged result), the *smaller* stack is dragged
onto the *larger*. Kitchen-table physics: humans grab the lighter
pile, and the heavier pile is more likely to already have room.

Enforcement target: at `merge_stack` emission (or as a rewrite
adjacent to `physicalPlan`), if `source.cards.length >
target.cards.length`, swap source ↔ target and flip side. The
solver's named source/target is not preserved through this rewrite —
only the resulting card order is.

The verbs whose composition can violate the small→large rule today
are interior-set extraction (the tail-merge step can have
tail.length > leftChunk.length; see
`extractAbsorbPrims` in `src/verbs.ts`). Most other verbs already
satisfy R2 by construction (extracted singletons, looses, and
stolen cards are length-1 sources).

### R3 — Plan for open space before single merges

A merge primitive (`merge_stack`, `merge_hand`) produces a stack
larger than either input. Before emitting the merge, the planner
verifies the post-merge stack at its *current* location clears the
pack-gap to all adjacent stacks. If clearance fails, a `move_stack`
pre-flight is injected first.

Tightening clause: **don't move if there's already room.** The
existing pre-flight logic always invokes `findOpenLoc` and may
relocate even when the current loc would have cleared. The target
behavior is:

1. Probe the existing target loc against `padRect(stackRect,
   PACK_GAP)` for the post-merge size.
2. If it clears all non-target stacks, no `move_stack` is emitted.
3. Otherwise, `findOpenLoc` picks a new slot.

Enforcement: `preFlightMergeStack` and `preFlightMergeHand` in
`src/geometry_plan.ts`. The "don't move if there's room" tightening
is currently MISSING — both functions always call `findOpenLoc`
unconditionally and skip the move only when the existing and
recommended loc happen to be byte-identical.

---

## Architecture — one solver pass + one physical-execution pass

```
solver (engine_v2) ─→ {placements, planDescs}
                                 │
                                 ▼
              physicalPlan(initialBoard, placements, planDescs)
                                 │
                                 ▼
                        Primitive[]  ─→  wire / transcript
```

Inside `physicalPlan`:

1. **Logical trace.** `emitLogicalTrace` emits the place_hand seed
   (multi-placement only) and walks `planDescs` through `expandVerb`,
   producing a geometry-agnostic primitive sequence.
2. **Hand-card lift.** `liftSinglePlacement` rewrites place_hand+
   future-merge into a direct `merge_hand` per R1.
3. **Global geometry.** `planActions` walks the lifted sequence once,
   pre-flighting splits and merges per R3.

Per-verb pre-flighting is *not* re-introduced inside `physicalPlan`.
The whole-program walk is the only geometry pass. `moveToPrimitives`
in `src/verbs.ts` still composes `expandVerb + planActions` for the
per-verb DSL test surface, but production does not call it.

---

## Implementation status (2026-05-04)

| Requirement | Status | Notes |
|---|---|---|
| R1 — direct hand-to-stack | partial | Single-placement turns lifted. Multi-placement (pair-stays-together easy win, etc.) is open. See `claude-steve/MINI_PROJECTS.md → SPATIAL_PLANNING`. |
| R2 — small-toward-large | not started | No rewrite emitter exists yet. Interior-set tail-merge in `extractAbsorbPrims` is the known violator. |
| R3 — pre-flight on all merges | partial | `preFlightMergeHand` added 2026-05-04 (parity with `preFlightMergeStack`). The "don't move if there's room" tightening is MISSING; both pre-flights call `findOpenLoc` unconditionally. |

The transcript writer (`src/transcript.ts`) routes every play through
`physicalPlan`. The per-play output is asserted clean by
`findViolation` at end-of-play; intermediate assertions were dropped
when per-verb expansion left the production path.

---

## Files

- `src/physical_plan.ts` — `physicalPlan`, `emitLogicalTrace`,
  `liftSinglePlacement`. The R1 enforcement layer.
- `src/geometry_plan.ts` — `planActions` and per-primitive
  pre-flights (`preFlightSplit`, `preFlightMergeStack`,
  `preFlightMergeHand`). The R3 enforcement layer.
- `src/verbs.ts` — `expandVerb` (pure, used by `physicalPlan`) and
  `moveToPrimitives` (per-verb wrapper, used by
  `verb_to_primitives_corpus.dsl` only).
- `src/transcript.ts` — production caller of `physicalPlan`.
- `src/primitives.ts` — primitive types + `applyLocally`.

---

## Related docs

- `ENGINE_V2.md` — what the solver hands to this layer.
- `../ARCHITECTURE.md` — repo-level layering and the gesture pipeline.
- `claude-steve/random249.md`, `random250.md` — design-conversation
  predecessors (frozen essays).
