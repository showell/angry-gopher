# Lyn Rummy UI DSL — working spec

**Status:** Draft 1 (2026-04-29). Ambitious on purpose — covers
both existing syntax (already tested) and proposed extensions
(not yet wired up). The goal is breadth over precision; the
examples are the spec.

---

## 1. What already exists (game logic + spatial)

These work today. Shown here as the foundation everything else
builds on.

```
# Spatial placement — coordinates are (left, top)
at (20, 70): KS AS 2S 3S

# Card notation
KS          # King of Spades, deck 1
8C'         # 8 of Clubs, deck 2
AH*         # Ace of Hearts, played from hand this turn

# Actions
action: split [KS AS 2S 3S]@2          # split after 2nd card
action: move_stack [2S 3S] -> (400, 300)
action: undo

# Assertions
expect_board_count: 6
expect_undoable: true
expect_stack: KS AS 2S 3S
expect: ok
expect: error
  stage: inventory
  message_contains: no source
```

---

## 2. Proposed: spatial constraint rules (Tier 1)

Decisions that are load-bearing across Elm + Python + Go.
These should be testable the same way referee scenarios are.

```
# floaterTopLeft convention — the canonical render position
# is the card's top-left corner in the frame where it was placed
rule floater_position
  card: 5H at (100, 80)
  frame: board
  expect_render_top_left: (100, 80)

# too_close feedback rule
rule proximity_reject
  existing_stack: at (100, 100): 5H 6H 7H
  proposed_drop: at (108, 105)
  expect_feedback: too_close

# valid landing — enough clearance
rule proximity_accept
  existing_stack: at (100, 100): 5H 6H 7H
  proposed_drop: at (200, 100)
  expect_feedback: ok

# find_open_loc — already tested, shown for completeness
scenario find_open_loc_empty_board
  op: find_open_loc
  card_count: 3
  expect:
    loc: (26, 26)
```

---

## 3. Proposed: interaction model (Tier 2 — drag state machine)

The states a card goes through during a drag. Ambitious: these
aren't wired yet but the state names are already in the Elm source.

```
# State machine for dragging a card from the board
interaction drag_board_card
  initial_state: idle

  transition: pick_up
    from: idle
    gesture: pointer_down on stack [5H 6H 7H] at card 5H
    to: holding
    expect_cursor: grabbing
    expect_card_lifted: 5H

  transition: hover_valid
    from: holding
    gesture: pointer_move to (200, 150)   # clear space, no collision
    to: hovering_valid
    expect_cursor: grabbing
    expect_feedback: none

  transition: hover_invalid
    from: holding
    gesture: pointer_move to (108, 105)   # too close to existing stack
    to: hovering_invalid
    expect_cursor: not-allowed
    expect_feedback: too_close

  transition: drop_commit
    from: hovering_valid
    gesture: pointer_up
    to: idle
    expect_card_placed: true
    expect_undoable: true

  transition: drop_cancel
    from: hovering_invalid
    gesture: pointer_up
    to: idle
    expect_card_returned: true
    expect_undoable: false

  transition: escape_cancel
    from: holding
    gesture: key Escape
    to: idle
    expect_card_returned: true
    expect_undoable: false
```

---

## 4. Proposed: undo model assertions (Tier 1 extension)

What exactly is restored on undo — position, identity, or both.

```
# Position is restored, not just identity
scenario undo_restores_position
  board:
    at (20, 70): KS AS 2S 3S
  steps:
    - action: move_stack [KS AS 2S 3S] -> (400, 300)
      expect_loc: (400, 300)
    - action: undo
      expect_loc: (20, 70)   # exact original position, not just "somewhere"

# Hand card is restored to hand, not left as a board floater
scenario undo_hand_merge_restores_to_hand
  hand: 7H'
  board:
    at (200, 40): 7S 7D 7C
  steps:
    - action: merge_hand 7H' -> [7S 7D 7C]
      expect_hand_count: 0
    - action: undo
      expect_hand_count: 1
      expect_hand_contains: 7H'
```

---

## 5. Proposed: replay fidelity (Tier 1 extension)

Replay reproduces the spatial path of the original move, not just
the end state.

```
scenario replay_preserves_floater_path
  desc: Replay of a move_stack shows the card at intermediate
        positions, not just snapping to the destination.
  original_action: move_stack [5H 6H 7H] from (20,70) -> (200, 150)
  replay_step: 0.0    # start of animation
    expect_loc: (20, 70)
  replay_step: 0.5    # midpoint
    expect_loc_between: (20,70) and (200,150)
  replay_step: 1.0    # end of animation
    expect_loc: (200, 150)
```

---

## Notes on syntax conventions

- Coordinates are always `(top, left)` — matching Elm's
  `{ top, left }` record field order. e.g. `at (20, 70)` means
  top=20, left=70.
- Card notation: `KS` = deck 1, `KS'` = deck 2, `KS*` =
  played from hand.
- `expect_feedback` values match wire format strings exactly:
  `too_close`, `crowded`, `ok`.
- State machine states: `idle`, `holding`, `hovering_valid`,
  `hovering_invalid`. These match Elm's `DragState` variants.
- `op:` is for cross-language conformance tests (run against
  both Elm and Python). Interaction model scenarios are
  Elm-only (no Python UI layer).
