# HINT_INFRASTRUCTURE — hint-for-hand build-out

Living doc. Sections flip from present to past tense as work lands.
See `HINT_PROJECTION.md` for background on the Python hint strategy.

---

## What we are building

Three connected pieces:

1. `format_hint(result)` in `agent_prelude.py` — canonical step-list function
2. DSL output from the game runner — `hint_demo.py` writes `.dsl` alongside transcript
3. `hint_for_hand` op in fixturegen + `test_dsl_conformance.py` — makes it testable

The Elm conformance side is deferred. All three pieces are Python-only for now.

---

## Step 1 — `format_hint` in `agent_prelude.py` ✓

`find_play` returned `{"placements": [card, ...], "plan": [(line, desc), ...]}`.

`format_hint` wraps that into a `[str]` where step 0 is explicit:

```
"place [JD:1 QD:1] from hand"
"peel TD from HELPER [TD JD QD KD], absorb onto trouble [JD:1 QD:1] → [TD JD:1 QD:1]"
```

`format_hint(None)` returns `[]` (stuck turn — no hint available).

`hint_scenario_dsl(name, hand, board, result)` was added alongside it —
produces DSL text for one `hint_for_hand` scenario. Both functions live
in `agent_prelude.py` and are the canonical hint-description layer.
Everything else — `hint_demo.py` display, DSL serialization, conformance
tests — calls `format_hint`, not inline formatting.

---

## Step 2 — DSL output from `hint_demo.py` ✓

`hint_demo.py` was updated to write a `.dsl` file alongside the human
transcript to stdout. File path:
`games/lynrummy/conformance/scenarios/hint_game_seed42.dsl`.

Each of the 3 turns became one `hint_for_hand` scenario. Example:

```
scenario turn_1_hint
  op: hint_for_hand
  hand: 3S:1 4S 8D:1 JD:1 4C:1 6D QD:1
  board:
    - KS AS 2S 3S
    - TD JD QD KD
    - ... (remaining stacks)
  expect_steps:
    - place [JD:1 QD:1] from hand
    - peel TD from HELPER [TD JD QD KD], absorb onto trouble [JD:1 QD:1] → [TD JD:1 QD:1] [→COMPLETE]
```

`hint_scenario_dsl(name, hand, board, result)` in `agent_prelude.py`
produced the DSL text. `hint_demo.py` called it for each turn and wrote
the combined output (with header comment) to the `.dsl` file.

The display was also updated to use `format_hint(result)` — "place from
hand" appears as Step 1 in the human transcript.

The board snapshot passed to `hint_scenario_dsl` captured state BEFORE
BFS cleanup, INCLUDING the stack placed in the previous turn — matching
the board seen by `find_play`.

The `.dsl` file was committed to the repo (snapshot test pattern —
run once, inspect output, commit as fixture).

---

## Step 3 — fixturegen + `test_dsl_conformance.py` ✓

### fixturegen (`cmd/fixturegen/main.go`)

The `hint_for_hand` op was added to the op registry (Python=true, Elm=false):

```go
{
    Name:   "hint_for_hand",
    Python: true,
    // No Elm emitter — Python-only for now.
},
```

The DSL format uses 2-space-indented fields (matching all other scenarios):

```
scenario turn_1_hint
  op: hint_for_hand
  hand: 3S:1 4S 8D:1 JD:1 4C:1 6D QD:1
  board:
    - KS AS 2S 3S
    - TD JD QD KD
    ...
  expect_steps:
    - place [JD:1 QD:1] from hand
    - peel TD from HELPER [...] → [...] [→COMPLETE]
```

Fixturegen parses:
- `hand:` scalar — space-separated card shorthands with `:N` deck suffix
- `board:` block — `- card1 card2 ...` rows (one stack per line, no location)
- `expect_steps:` — block of `- <text>` lines, OR scalar `[]` for stuck/no-hint

Three new JSON fields in `conformance_fixtures.json` carry the hint data in
label-string form so the Python handler can call `agent_prelude` directly:
- `"hint_hand"`: `["3S:1", "4S", "8D:1", ...]`
- `"hint_board"`: `[["KS", "AS", ...], ...]`
- `"hint_steps"`: `["place [...] from hand", ...]`

The `elmScenarioBody` function was updated to emit `Expect.pass` (not
`Expect.fail`) for Python-only ops so they appear in the Elm test file
without spurious failures.

`hint_scenario_dsl` in `agent_prelude.py` was also corrected to output
the proper indented DSL format (2 spaces for fields, 4 spaces for block
item lines).

### `test_dsl_conformance.py`

A `_run_hint_for_hand(sc)` handler was added:

```python
def _run_hint_for_hand(sc):
    hand = [parse_card_label(tok) for tok in sc["hint_hand"]]
    board = [[parse_card_label(tok) for tok in stack]
             for stack in sc["hint_board"]]
    result = agent_prelude.find_play(hand, board)
    got = agent_prelude.format_hint(result)
    want = sc["hint_steps"]
    # ... assert got == want with clear diff message
```

`parse_card_label` is `rules.card.card` — the existing parser that
handles `"3S:1"` → `(3, 2, 1)`, `"4S"` → `(4, 2, 0)`, etc.

`"hint_for_hand"` was added to the DISPATCH table. The manifest
cross-check (`_verify_dispatch_matches_manifest`) catches any future
drift between the Go registry and the Python runner.

All 3 hint scenarios pass (`turn_1_hint`, `turn_2_hint`, `turn_3_hint`)
and the full `ops/check-conformance` gate is green (773 Elm + 99 Python).

---

## End-to-end flow (target state)

```
python3 tools/hint_demo.py
  → stdout: human transcript
  → writes: conformance/scenarios/hint_game_seed42.dsl

go run ./cmd/fixturegen ./games/lynrummy/conformance/scenarios/*.dsl
  → regenerates conformance_fixtures.json (includes hint_for_hand scenarios)

python3 test_dsl_conformance.py
  → runs hint_for_hand scenarios
  → calls find_play + format_hint, asserts step lists match

ops/check-conformance  ← runs all of the above
```

---

## Deferred

- Elm emitter in fixturegen (needs `findPlay` + `formatHint` in Elm first)
- Pair-projection scenarios (seed-42 already exercises turns 1 and 3 with pairs)
- Explicit `stuck` scenario (no hint) — easy to add once infrastructure is in
