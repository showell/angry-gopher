# Wing-oracle conformance scenarios.
# Ported from games/lynrummy/elm/tests/Game/WingOracleTest.elm
# — the `wingsForStack` describe block (4 tests, lines 49–101).
#
# wingsForStack finds merge-target wings for a board stack being dragged.
# Wings are matched by (target cards, side).
#
# All ops are Elm-only (no Python gesture layer).
#
# Layout note: board/source blocks use `at (top, left): cards`
# (top first, left second), matching the DSL convention used by gesture.dsl.


scenario wings_for_stack_567_onto_234_right
  desc: 567 dragged toward 234 (right half of a split rb-run) offers a right wing on 234.
  op: wings_for_stack
  board:
    at (200, 100): 2C 3D 4C
    at (200, 300): 5H 6S 7H
  source:
    at (200, 300): 5H 6S 7H
  expect_wings:
    - target: 2C 3D 4C
      side: Right


scenario wings_for_stack_234_onto_567_left
  desc: 234 dragged toward 567 offers a left wing on 567 (the other direction).
  op: wings_for_stack
  board:
    at (200, 100): 2C 3D 4C
    at (200, 300): 5H 6S 7H
  source:
    at (200, 100): 2C 3D 4C
  expect_wings:
    - target: 5H 6S 7H
      side: Left


scenario wings_for_stack_no_valid_merge
  desc: No wings when a merge would not form a valid group (aces + sevens).
  op: wings_for_stack
  board:
    at (200, 100): AC AD AH
    at (200, 300): 7C 7D 7H
  source:
    at (200, 100): AC AD AH
  expect_wings: []


scenario wings_for_stack_self_excluded
  desc: Self is excluded — no wings when board contains only the source stack.
  op: wings_for_stack
  board:
    at (200, 100): 2C 3D 4C
  source:
    at (200, 100): 2C 3D 4C
  expect_wings: []


scenario wings_for_hand_card_7S_onto_7set_right
  desc: 7S dragged from hand onto [7H 7D 7C] offers both Left and Right wings — sets accept cards on either side.
  op: wings_for_hand_card
  hand_card: 7S
  board:
    at (200, 100): 7H 7D 7C
  expect_wings:
    - target: 7H 7D 7C
      side: Left
    - target: 7H 7D 7C
      side: Right


scenario wings_for_hand_card_duplicate_rejected
  desc: 7H is already in the set — duplicate card gets zero wings (the key duplicate-rejection rule).
  op: wings_for_hand_card
  hand_card: 7H
  board:
    at (200, 100): 7H 7D 7C
  expect_wings: []


scenario wings_for_hand_card_no_valid_group
  desc: KS cannot extend a hearts run [4H 5H 6H] — no valid group, zero wings.
  op: wings_for_hand_card
  hand_card: KS
  board:
    at (200, 100): 4H 5H 6H
  expect_wings: []


scenario wings_for_hand_card_onto_run_right
  desc: 7H extends pure-run [4H 5H 6H] on the right — expects a right wing.
  op: wings_for_hand_card
  hand_card: 7H
  board:
    at (200, 100): 4H 5H 6H
  expect_wings:
    - target: 4H 5H 6H
      side: Right


scenario wings_for_stack_dual_deck_both_are_targets
  desc: Two stacks with equal values but different decks are both valid Right-wing targets for 5H-6S-7H. Guards against collapsing them by value+suit alone.
  op: wings_for_stack
  board:
    at (200, 100): 2C 3D 4C
    at (200, 300): 2C' 3D' 4C'
    at (200, 500): 5H 6S 7H
  source:
    at (200, 500): 5H 6S 7H
  expect_wings:
    - target: 2C 3D 4C
      side: Right
    - target: 2C' 3D' 4C'
      side: Right
