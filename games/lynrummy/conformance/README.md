# LynRummy conformance scenarios

**As-of:** 2026-04-15
**Confidence:** Firm — DSL shipped 2026-04-14, replaced JSON fixtures, in use across Go+Elm.
**Durability:** Stable until fixturegen evolves; grammar is small and intentionally extensible.

Scenarios for cross-language correctness checks on the LynRummy
game logic (referee + tricks). Shared between the Go impl in
`../` and the Elm impl in `../../elm-lynrummy/src/LynRummy/`.

## File layout

```
conformance/
├── README.md           <-- this file
└── scenarios/
    ├── tricks.dsl      <-- trick_first_play scenarios (all 7 tricks)
    └── referee.dsl     <-- validate_game_move / validate_turn_complete
```

## Authoring

Scenarios live in `scenarios/*.dsl` as the single source of truth.
Hand-edit them; generate from them.

Grammar is line-oriented with 2-space indent. Per-scenario shape:

```
scenario <name>
  desc: <one-line human description>
  op: trick_first_play | validate_game_move | validate_turn_complete
  [trick: <trick_id>]           # trick_first_play only
  hand: <cards>                 # trick_first_play: the hand
  board: / board_before: ...    # depends on op
  [stacks_to_remove:]           # validate_game_move
  [stacks_to_add:]              # validate_game_move
  [hand_cards_played:]          # validate_game_move
  expect: ok | no_plays | play | error
    [hand_played: ...]          # expect: play
    [board_after: ...]          # expect: play
    [stage: ...]                # expect: error
    [message_contains: ...]     # expect: error
```

Card literal: `<value><suit>[deck][state]` where
- value: `A 2..9 T J Q K`
- suit: `H S D C`
- deck: `'` suffix = deck 1 (omitted = deck 0)
- state on board: `*` = FreshlyPlayed, `**` = FreshlyPlayedByLastPlayer
  (omitted on board = FirmlyOnBoard; hand state is always HandNormal)

Stack literal: `at (<top>,<left>): <card> <card> ...`

Comments: `#` to end-of-line.

## Generating tests

After any `.dsl` edit:

```bash
cd ~/showell_repos/angry-gopher
go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl
```

Emits:
- `lynrummy/tricks/dsl_conformance_test.go` (Go native tests)
- `elm-lynrummy/tests/LynRummy/DslConformanceTest.elm` (Elm native tests)

Both are marked `GENERATED — DO NOT EDIT`. Check both files in
alongside `.dsl` edits; reviewers should see the test diff.

## Running

```bash
# Go
go test ./lynrummy/...

# Elm
cd elm-lynrummy && ./check.sh
```

## Why not JSON

The DSL replaced a hand-authored JSON fixture suite on 2026-04-14.
JSON authoring was 4× more verbose per scenario, required hand-
computed `board_after` arrays (transcription errors masked real
bugs — see commit `5de4574`), and the JSON loaders in each target
language added wire-format concerns to the test path. Native code
generation via DSL eliminates both.

## When the DSL doesn't fit

If a future scenario needs something the DSL can't express
(random inputs with seed, property-based generation, scenarios
shared across fixture families), extend `cmd/fixturegen`. The
parser is intentionally small (~600 lines) and designed for
extension. Don't bolt on a sidecar JSON file — that re-introduces
the authoring bifurcation we deleted.
