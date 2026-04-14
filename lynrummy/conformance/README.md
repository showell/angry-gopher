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
| `operation` | `"validate_game_move"` \| `"validate_turn_complete"` | yes | Which referee entry point to call. |
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
