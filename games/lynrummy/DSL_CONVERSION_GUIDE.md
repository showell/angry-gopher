# Lyn Rummy DSL conversion guide

Audience: a future agent or developer picking up where this work left off.

---

## Why this exists — dispute resolution

The DSL is Steve's primary reason for wanting this work done. The core insight:
when Steve notices something unexpected in the UI and asks "is this a bug or is it
by design?", the answer should be a lookup against a spec, not a conversation.

Without DSL scenarios, the answer is: read the Elm source, trace the logic, form an
opinion. With DSL scenarios, the answer is: find the relevant `.dsl` file, read the
scenario that names the rule, compare expected vs. actual.

Concretely: "Claude finds the spec and says it's by design, then Steve looks at the
DSL to find what was miscommunicated." The DSL is where design intent is written
down in a form that's both executable and human-readable.

A secondary benefit: cross-language conformance. Some scenarios run against both
Elm and Python, locking the rule across both implementations.

---

## How the system works

```
games/lynrummy/conformance/scenarios/*.dsl
        ↓  (cmd/fixturegen/main.go parses + emits)
games/lynrummy/elm/tests/Game/DslConformanceTest.elm
        ↓  (ops/check-conformance runs everything)
elm-test + Python conformance suite + elm-review
```

The canonical command is `ops/check-conformance`. Always run it before reporting
done. It compiles Elm, runs all tests, and runs elm-review.

`cmd/fixturegen/main.go` is the code generator. It has **four design principles at
the top** (lines 31–54) — read them before adding any new op.

---

## What's already covered (189 scenarios, 770 tests)

| File | Scenarios | What it encodes |
|------|-----------|-----------------|
| `replay_walkthroughs.dsl` | 27 | Replay fidelity across all primitives |
| `planner.dsl` + corpus files | 51 | BFS planner: move enumeration, solve paths |
| `tricks.dsl` | 18 | Strategy/hint rules |
| `board_geometry.dsl` | 16 | Proximity, overlap, TooClose/Crowded/Illegal |
| `gesture.dsl` | 11 | Full drag state machine |
| `referee.dsl` | 10 | Referee validation rules |
| `wing_oracle.dsl` | 9 | `wingsForStack` (4) + `wingsForHandCard` (4) + dual-deck guard (1) |
| `click_arbitration.dsl` | 8 | Click-vs-drag threshold: distSquared > 9 kills intent |
| `undo_walkthrough.dsl` | 7 | Undo round-trips for all 5 primitives + position invariants |
| `place_stack.dsl` | 5 | Place stack scenarios |
| `drag_invariant.dsl` | 5 | floaterTopLeft invariant, pathFrame correctness |
| `click_agent_play.dsl` | 4 | Click-agent play scenarios |

Three Elm test files were **fully superseded and deleted** in a prior session:
`BoardGeometryTest.elm`, `DragInvariantTest.elm`, `GestureTest.elm`.

---

## Selection criteria — what is worth porting?

**High value — port these:**
- Rules that answer "is this a bug or by design?" — merge rejection, duplicate
  card rejection, direction constraints, position invariants
- Cross-language rules — anything Python and Elm both implement
- Tests where the Elm code obscures the rule (lots of boilerplate, buried intent)

**Low value — leave as Elm tests:**
- Pure math/geometry helpers (`distSquared`, `isCursorInRect`) — the Elm tests
  are already clean, no boilerplate to remove
- Implementation plumbing (`collapseUndos`, `canUndoThisTurn`) — tests an
  internal data structure, not a game rule
- Wire format round-trips — serialization layer, not game logic
- Tests already implicitly covered by higher-level scenarios

**Ask before adding a new fixturegen op:** if a test can be expressed with existing
ops (`undo_walkthrough`, `wings_for_stack`, etc.), prefer that. New ops cost
fixturegen complexity; only add them when the rule genuinely needs its own shape.

---

## How to do a conversion

1. **Read the Elm test file.** Understand its structure before deciding anything.

2. **Filter by value.** Apply the criteria above. A 200-line test file might yield
   only 4 high-value scenarios worth porting.

3. **Check whether the op already exists.** Grep fixturegen for the function name
   being tested. If an op exists, write the DSL directly. If not, decide whether
   a new op is warranted (usually yes if the rule is game-logic, no if it's a
   helper).

4. **Add scenarios to the right `.dsl` file.** If the test fits an existing file
   (e.g. wing logic → `wing_oracle.dsl`), add there. If it's a new domain, create
   a new file.

5. **If adding a new op to fixturegen:** follow all four design principles. Add a
   per-op `Expect*` type (not generic map). One emitter function per op. Use
   `toKey` / card-content comparison rather than board lookups with fallbacks —
   the `wings_for_stack` emitter is the canonical pattern after the fragility fix
   in this session.

6. **Run `ops/check-conformance`.** Gate must be green before calling it done.

7. **SUPERSEDED marker:** if the entire Elm test file is now covered by DSL, add
   `-- SUPERSEDED by <dsl-file>.dsl` at the top. Deletion comes later, once
   someone verifies coverage is complete.

---

## Remaining work — prioritized

### High value

**`BoardActionsTest.elm` (313 lines) — partial conversion**

The high-value subset:
- Wrong-direction merge rejected: `tryStackMerge [4H 5H 6H] left [7H 8H 9H]`
  → Nothing. Already documented in wing_oracle (only Right wing appears), but
  a direct negative scenario is clearer.
- `findAllHandMerges` returning empty for an incompatible card. This one is
  already covered by `wing_oracle.dsl`'s `wings_for_hand_card_no_valid_group`.

Skip: `tryHandMerge`/`tryStackMerge`/`placeHandCard`/`moveStackTo` struct-field
tests — they inspect `BoardChange` internals (count of stacksToRemove etc.).
Those are implementation tests, not rule tests.

**`HintTest.elm` (109 lines)**

Tests the hint/strategy layer. Worth a look — if it encodes rules about when
hints fire vs. don't fire, those belong in DSL form alongside `tricks.dsl`.

**`ReducerTest.elm` (209 lines)**

Read it first. If it tests game-state transitions (e.g. "after completing a turn,
scores update correctly"), those could be high-value scenarios.

**`PlayerTurnTest.elm` (173 lines)**

Similar — if it encodes turn-boundary rules, worth porting.

### Low value (skip unless specifically tasked)

- `GestureArbitrationTest.elm` — remaining tests are `distSquared`, `isCursorInRect`
  (pure geometry), `applySplit` (covered by split actions). Not worth porting.
- `WingOracleTest.elm` — remaining test is `wingBoardRect` (positional math, Elm-only).
- `UndoTest.elm` — remaining sections are `collapseUndos` (action log plumbing),
  `canUndoThisTurn` (already covered via `expect_undoable:` in existing scenarios).
- `WireTest.elm` — wire format round-trips. Serialization layer, not game logic.
- `CardStackTest.elm` — pure helpers: `agedFromPriorTurn`, `maybeMerge`, etc.

---

## Key gotchas learned during this session

**Coordinate convention:** DSL uses `at (top, left)` — top first, left second.
Matches Elm's `{ top, left }` record field order. Easy to get backwards.

**Sets vs. runs for wing direction:** a hand card can merge onto a set from either
side (Left and Right wings both fire). A run extension only offers the
directionally-correct side. The `wing_oracle.dsl` `wings_for_hand_card_7S_onto_7set`
scenario captures this distinction.

**Wing comparison — use `toKey`, not board lookups:** the `wings_for_stack` and
`wings_for_hand_card` emitters use `toKey w = ( List.map .card w.target.boardCards, w.side )`
to strip `loc` before comparing. A `Maybe.withDefault` fallback on a board filter
was the old approach — it masked typos. Don't reintroduce it.

**`desc:` is single-line only.** Multi-line desc blocks crash the parser.

**`expect_stack:` is single-slot.** One stack per step. If you need to assert two
stacks in the same step (e.g. after a merge undo), add a trailing observation step
with no action.
