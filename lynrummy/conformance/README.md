# LynRummy referee conformance fixtures — format spec

A *conformance fixture* is a JSON file that pins one referee
scenario as a `(input, expected output)` pair. Each
implementation of the LynRummy referee (TS, Go, Elm) reads the
fixture, runs its referee, encodes the result, and asserts
byte-equivalence with the expected.

If all three impls pass the same fixture suite, they agree on
the rules. Drift in any impl flips a CI test in the others.

This is Phase 2 of the cross-language conformance work; see
`PORTING_CHEAT_SHEET.md` → "Find the boundaries" and
`PORTING_NOTES.md` insight #19 for the methodology.

---

## File shape

One fixture per file. Filename is the scenario name:
`valid_extend_run_with_8H.json`, `inventory_card_from_nowhere.json`,
etc. Snake_case to match LynRummy wire-format conventions.

Each file is a single JSON object with these top-level fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Should match the filename stem. |
| `description` | string | yes | One sentence; what the scenario tests. |
| `operation` | see below | yes | Which entry point to call. |

**Valid `operation` values:**
- `"validate_game_move"` — referee mid-turn ruling.
- `"validate_turn_complete"` — referee turn-boundary ruling.
- `"trick_first_play"` — run a single trick's `find_plays()` and assert on the first Play it returns (or on "no plays"). See "Trick operations" below.
| `input` | object | yes | Operation-specific input. See below. |
| `bounds` | `BoardBounds` JSON | yes | The board bounds for the scenario. |
| `expected` | object | yes | Expected referee output. See below. |

## `input` shape

For `operation: "validate_game_move"`:

```json
{
  "board_before": [/* CardStack[] */],
  "stacks_to_remove": [/* CardStack[] */],
  "stacks_to_add": [/* CardStack[] */],
  "hand_cards_played": [/* HandCard[], optional */]
}
```

The `hand_cards_played` field MAY be omitted when empty
(matches TS's optional-field semantics; matches Elm's
encoder behavior).

For `operation: "validate_turn_complete"`:

```json
{
  "board": [/* CardStack[] */]
}
```

## `expected` shape

For success:

```json
{ "ok": true }
```

For failure:

```json
{
  "ok": false,
  "error": {
    "stage": "protocol" | "geometry" | "semantics" | "inventory",
    "message_substr": "<a substring the error message must contain>"
  }
}
```

**Why `message_substr` instead of exact `message`:** error
message wording varies subtly across impls (e.g., one might
print `"card A♥"` with a suit emoji, another `"card AH"` with
the letter). Stage is the load-bearing assertion; substring on
message is enough to confirm the error is the right *kind*
without locking in exact wording.

If a fixture truly needs an exact match (e.g., wire-protocol
debugging), use a future `"message"` field instead. Default is
substring.

## Example fixtures (illustrative)

### Valid move

```json
{
  "name": "valid_extend_run_with_8H",
  "description": "Player extends a 5H-7H run by playing the 8 of hearts from hand.",
  "operation": "validate_game_move",
  "input": {
    "board_before": [
      {
        "board_cards": [
          { "card": { "value": 5, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 6, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 7, "suit": 3, "origin_deck": 0 }, "state": 0 }
        ],
        "loc": { "top": 10, "left": 10 }
      }
    ],
    "stacks_to_remove": [
      {
        "board_cards": [
          { "card": { "value": 5, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 6, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 7, "suit": 3, "origin_deck": 0 }, "state": 0 }
        ],
        "loc": { "top": 10, "left": 10 }
      }
    ],
    "stacks_to_add": [
      {
        "board_cards": [
          { "card": { "value": 5, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 6, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 7, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 8, "suit": 3, "origin_deck": 0 }, "state": 1 }
        ],
        "loc": { "top": 10, "left": 10 }
      }
    ],
    "hand_cards_played": [
      { "card": { "value": 8, "suit": 3, "origin_deck": 0 }, "state": 0 }
    ]
  },
  "bounds": { "max_width": 800, "max_height": 600, "margin": 5 },
  "expected": { "ok": true }
}
```

### Inventory failure

```json
{
  "name": "inventory_card_from_nowhere",
  "description": "Player adds cards to the board that weren't on the board or in their declared hand.",
  "operation": "validate_game_move",
  "input": {
    "board_before": [],
    "stacks_to_remove": [],
    "stacks_to_add": [
      {
        "board_cards": [
          { "card": { "value": 1, "suit": 3, "origin_deck": 0 }, "state": 1 },
          { "card": { "value": 2, "suit": 3, "origin_deck": 0 }, "state": 1 },
          { "card": { "value": 3, "suit": 3, "origin_deck": 0 }, "state": 1 }
        ],
        "loc": { "top": 10, "left": 10 }
      }
    ],
    "hand_cards_played": [
      { "card": { "value": 1, "suit": 3, "origin_deck": 0 }, "state": 0 },
      { "card": { "value": 2, "suit": 3, "origin_deck": 0 }, "state": 0 }
    ]
  },
  "bounds": { "max_width": 800, "max_height": 600, "margin": 5 },
  "expected": {
    "ok": false,
    "error": {
      "stage": "inventory",
      "message_substr": "no source"
    }
  }
}
```

### Turn-complete check

```json
{
  "name": "turn_complete_rejects_incomplete",
  "description": "Two-card stack is fine mid-turn but rejected at turn boundary.",
  "operation": "validate_turn_complete",
  "input": {
    "board": [
      {
        "board_cards": [
          { "card": { "value": 1, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 2, "suit": 3, "origin_deck": 0 }, "state": 0 }
        ],
        "loc": { "top": 10, "left": 10 }
      }
    ]
  },
  "bounds": { "max_width": 800, "max_height": 600, "margin": 5 },
  "expected": {
    "ok": false,
    "error": {
      "stage": "semantics",
      "message_substr": "incomplete"
    }
  }
}
```

## Trick operations

For `operation: "trick_first_play"`:

The fixture names one registered trick, supplies a `(hand, board)`
input state, and asserts on what `trick.find_plays(hand, board)[0]`
should produce (or that the list should be empty).

Trick fixtures live under `conformance/tricks/` as a subdirectory —
tricks are structurally different from referee operations (they
generate moves rather than ruling on them), and grouping keeps the
fixture list scannable.

### `input` shape

```json
{
  "trick_id": "direct_play",
  "hand": [ /* HandCard[] */ ],
  "board": [ /* CardStack[] */ ]
}
```

`trick_id` matches the Trick's `id` field (e.g. `direct_play`,
`hand_stacks`, `rb_swap`).

### `expected` shape

For "no plays found":

```json
{ "ok": true, "no_plays": true }
```

For "first play is X":

```json
{
  "ok": true,
  "play": {
    "hand_cards_played": [ /* HandCard[] */ ],
    "board_after": [ /* CardStack[] — after play.apply(board) */ ]
  }
}
```

**Why first play only:** `find_plays` may return multiple Plays;
the order is trick-internal and not worth locking into fixtures at
this stage. Asserting on the first one is enough to catch the
common drift cases; a future `trick_all_plays` operation can pin
the full list if we need it.

**Why `board_after` is byte-equal:** locks in the exact merge
behavior — any drift in location arithmetic, state transitions, or
stack identity shows up as a fixture failure.

### Example

```json
{
  "name": "direct_play_extends_heart_run",
  "description": "Hand 8H extends an existing 5H-6H-7H run at the right end.",
  "operation": "trick_first_play",
  "input": {
    "trick_id": "direct_play",
    "hand": [
      { "card": { "value": 8, "suit": 3, "origin_deck": 0 }, "state": 0 }
    ],
    "board": [
      {
        "board_cards": [
          { "card": { "value": 5, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 6, "suit": 3, "origin_deck": 0 }, "state": 0 },
          { "card": { "value": 7, "suit": 3, "origin_deck": 0 }, "state": 0 }
        ],
        "loc": { "top": 10, "left": 10 }
      }
    ]
  },
  "bounds": { "max_width": 800, "max_height": 600, "margin": 5 },
  "expected": {
    "ok": true,
    "play": {
      "hand_cards_played": [
        { "card": { "value": 8, "suit": 3, "origin_deck": 0 }, "state": 0 }
      ],
      "board_after": [
        {
          "board_cards": [
            { "card": { "value": 5, "suit": 3, "origin_deck": 0 }, "state": 0 },
            { "card": { "value": 6, "suit": 3, "origin_deck": 0 }, "state": 0 },
            { "card": { "value": 7, "suit": 3, "origin_deck": 0 }, "state": 0 },
            { "card": { "value": 8, "suit": 3, "origin_deck": 0 }, "state": 1 }
          ],
          "loc": { "top": 10, "left": 10 }
        }
      ]
    }
  }
}
```

---

## Lessons from the first real integration (2026-04-14)

Retroactively running the TrickBag against live game events
surfaced two bugs the fixture suite had missed. Both are examples
of *fixture selection bias*: fixtures were authored from the
canonical happy-path shape of a game and never exercised the
edges that real browsers produce.

**Bug 1: `maybeMerge` wrongly rejected `Incomplete` (2-card)
results.** TS and Elm both accept 2-card stacks mid-turn; the
semantics check runs only at turn boundaries. All 12 initial
fixtures used ≥3-card merges (immediately-complete groups), so no
fixture ever produced an Incomplete result. The bug was invisible
until a live Cat game dropped a lone card and then extended it.

**Bug 2: `Location.UnmarshalJSON` didn't accept fractional
pixels.** Cat's drag-and-drop sends values like
`401.9333190917969`; all hand-authored fixtures used integer
coords inherited from the dealer's initial board (`20 + row*60`
etc.). The wire never carried a float through the fixture suite.

**Authoring guidance to avoid the same trap:**

- If a trick's detector has a branch for "extend a 1-card stack,"
  "peel into a 2-card remainder," "merge onto a stack with a
  freshly-played card already in it" — write a fixture for it.
  Canonical happy paths aren't enough.
- If a field is defined as `int` in one impl but produced by a
  browser via floating-point math elsewhere, write at least one
  fixture with fractional values.
- Before declaring a fixture suite "done," exercise the actual
  wire against at least one live session and see what new cases
  surface. Static coverage does not predict live coverage.

Regression tests for both bugs landed alongside the fixes:
- `lynrummy/card_stack_test.go` — `TestMaybeMergeAcceptsTwoCardIncomplete`,
  `TestLocationUnmarshalAcceptsFractional`,
  `TestCardStackJSONWithFractionalLoc`.
- `conformance/tricks/direct_play_extends_loose_card.json` —
  end-to-end fixture for the 2-card Incomplete path.

---

## Fixture home

This directory (`angry-gopher/lynrummy/conformance/`) is the
canonical home for LynRummy referee conformance fixtures.
Other repos (`angry-cat`, `elm-lynrummy`) reference the JSON
files here from their test suites.

---

## Loader contract (for each language)

Each language's test runner needs a tiny loader:

1. Discover all `*.json` files under this directory.
2. For each file: parse the fixture, decode `input` and `bounds`
   into the language's referee types, run the appropriate referee
   call (`validateGameMove` or `validateTurnComplete`), encode
   the result, and assert against `expected`.
3. Report failures with the fixture name + the actual output.

Loaders by repo:

- **Go** — `angry-gopher/lynrummy/conformance_test.go` (TBD)
- **TS** — `angry-cat/src/tests/conformance_test.ts` (TBD)
- **Elm** — `elm-lynrummy/tests/LynRummy/ConformanceTest.elm` (TBD)
