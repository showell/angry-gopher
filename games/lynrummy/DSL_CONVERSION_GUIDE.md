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

A secondary benefit: cross-language conformance. Scenarios run against both
Elm and TypeScript, locking the rule across both implementations.

---

## How the system works

```
games/lynrummy/conformance/scenarios/*.dsl
        ↓  (parsed natively at test time by both runners)
TS: games/lynrummy/ts/test/conformance_dsl.ts + per-test consumers
Elm: tests/Lib/ConformanceDsl.elm  →  tests/Lib/ConformanceTests.elm
        ↓  (ops/check runs everything <20s; ops/check_full adds the slow tier)
elm-test + TS conformance suite + elm-review + go build
```

The canonical command is `ops/check` (pre-commit gate, ~20s). Always run it before
reporting done. It runs `ops/test_ts` + `ops/test_elm` + `ops/test_go`.

Each `op:` in a `.dsl` scenario dispatches at test time to a hand-written
verifier — in Elm via the `verify` case-match in
`tests/Lib/ConformanceTests.elm`, in TS via per-test runners. There is no
codegen step.

---

## What's already covered

Browse `conformance/scenarios/*.dsl` — each file's name and top-comment names its
domain (replay walkthroughs, planner corpus, referee, wing oracle, click
arbitration, undo, board geometry, gesture, etc.). The op set is whatever the
`verify` dispatcher in `tests/Lib/ConformanceTests.elm` cases on; grep that to
enumerate live ops.

---

## Selection criteria — what is worth porting?

**High value — port these:**
- Rules that answer "is this a bug or by design?" — merge rejection, duplicate
  card rejection, direction constraints, position invariants
- Cross-language rules — anything Elm and TS both implement
- Tests where the Elm code obscures the rule (lots of boilerplate, buried intent)

**Low value — leave as Elm tests:**
- Pure math/geometry helpers (`distSquared`, `isCursorInRect`) — the Elm tests
  are already clean, no boilerplate to remove
- Implementation plumbing (`collapseUndos`, `canUndoThisTurn`) — tests an
  internal data structure, not a game rule
- Wire format round-trips — serialization layer, not game logic
- Tests already implicitly covered by higher-level scenarios

**Ask before adding a new op:** if a test can be expressed with existing ops
(`undo_walkthrough`, `wings_for_stack`, etc.), prefer that. New ops cost a
verifier in each runner that needs to dispatch on them; only add them when the
rule genuinely needs its own shape.

---

## How to do a conversion

1. **Read the Elm test file.** Understand its structure before deciding anything.

2. **Filter by value.** Apply the criteria above. A 200-line test file might yield
   only 4 high-value scenarios worth porting.

3. **Check whether the op already exists.** Grep the `verify` case-match in
   `tests/Lib/ConformanceTests.elm` (and the TS dispatcher) for the op name.
   If it exists, write the DSL directly. If not, decide whether a new op is
   warranted (usually yes if the rule is game-logic, no if it's a helper).

4. **Add scenarios to the right `.dsl` file.** If the test fits an existing file
   (e.g. wing logic → `wing_oracle.dsl`), add there. If it's a new domain, create
   a new file.

5. **If adding a new op:** add a `case "op_name" -> verifyX sc` arm in
   `tests/Lib/ConformanceTests.elm` and a matching TS dispatcher arm if the
   rule is cross-language. Compare via stripped keys (cards + side, not full
   stack values with locs) so a typo produces a direct mismatch rather than a
   confusing lookup failure — the `wings_for_stack` verifier is the canonical
   pattern.

6. **Run `ops/check`.** Gate must be green before calling it done. If the change
   touches BFS / agent / bucket pipeline code, run `ops/check_full` instead.

7. **SUPERSEDED marker:** if the entire Elm test file is now covered by DSL, add
   `-- SUPERSEDED by <dsl-file>.dsl` at the top. Deletion comes later, once
   someone verifies coverage is complete.

---

## Remaining conversion opportunities

Several `tests/Lib/*Test.elm` files in the Elm tree still encode rules that
could move to DSL — `BoardActionsTest`, `HintTest`, `ReducerTest`,
`PlayerTurnTest`. Skim each before porting; some sections test
implementation plumbing (`BoardChange` internals, `collapseUndos`, pure
geometry) that's better left as Elm unit tests. The selection criteria above
apply: rules → DSL, plumbing → unit test.

`tests/Lib/{CardStack,Wire,GestureArbitration,WingOracle}Test.elm` are mostly
serialization round-trips and pure helpers; leave them alone.

---

## Key gotchas

**Two coordinate conventions, both pinned by Elm source:** the
board-block grammar uses `at (top, left): cards`. The action-log grammar
(`actions.dsl`, the wire) uses `(left, top)` inside `-> (...)`,
`at (...)` stack-refs, and `path (...)` samples — that's what Elm's
`Lib.GameEvent.locStr` emits. Don't try to unify them; the live wire is
where the latter convention lives.

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
