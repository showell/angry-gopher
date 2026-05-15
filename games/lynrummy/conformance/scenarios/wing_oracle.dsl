# wingsForStack finds merge-target wings for a board stack being dragged.
# Wings are matched by (target cards, side).
#
# Layout note: board/source blocks use `at (top, left): cards`
# (top first, left second).


scenario wings_for_stack_567_onto_234_right
  desc: 567 dragged toward 234 (right half of a split rb-run) offers a right wing on 234.
  op: wings_for_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
    at (300,200): 5♥ 6♠ 7♥
  source:
    at (300,200): 5♥ 6♠ 7♥
  expect_wings:
    - target: 2♣ 3♦ 4♣
      side: Right


scenario wings_for_stack_234_onto_567_left
  desc: 234 dragged toward 567 offers a left wing on 567 (the other direction).
  op: wings_for_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
    at (300,200): 5♥ 6♠ 7♥
  source:
    at (100,200): 2♣ 3♦ 4♣
  expect_wings:
    - target: 5♥ 6♠ 7♥
      side: Left


scenario wings_for_stack_no_valid_merge
  desc: No wings when a merge would not form a valid group (aces + sevens).
  op: wings_for_stack
  board:
    at (100,200): A♣ A♦ A♥
    at (300,200): 7♣ 7♦ 7♥
  source:
    at (100,200): A♣ A♦ A♥


scenario wings_for_stack_self_excluded
  desc: Self is excluded — no wings when board contains only the source stack.
  op: wings_for_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
  source:
    at (100,200): 2♣ 3♦ 4♣


scenario wings_for_hand_card_7♠_onto_7set_right
  desc: 7♠ dragged from hand onto [7♥ 7♦ 7♣] offers both Left and Right wings — sets accept cards on either side.
  op: wings_for_hand_card
  hand_card: 7♠
  board:
    at (100,200): 7♥ 7♦ 7♣
  expect_wings:
    - target: 7♥ 7♦ 7♣
      side: Left
    - target: 7♥ 7♦ 7♣
      side: Right


scenario wings_for_hand_card_duplicate_rejected
  desc: 7♥ is already in the set — duplicate card gets zero wings (the key duplicate-rejection rule).
  op: wings_for_hand_card
  hand_card: 7♥
  board:
    at (100,200): 7♥ 7♦ 7♣


scenario wings_for_hand_card_no_valid_group
  desc: K♠ cannot extend a hearts run [4♥ 5♥ 6♥] — no valid group, zero wings.
  op: wings_for_hand_card
  hand_card: K♠
  board:
    at (100,200): 4♥ 5♥ 6♥


scenario wings_for_hand_card_onto_run_right
  desc: 7♥ extends pure-run [4♥ 5♥ 6♥] on the right — expects a right wing.
  op: wings_for_hand_card
  hand_card: 7♥
  board:
    at (100,200): 4♥ 5♥ 6♥
  expect_wings:
    - target: 4♥ 5♥ 6♥
      side: Right


scenario wings_for_stack_dual_deck_both_are_targets
  desc: Two stacks with equal values but different decks are both valid Right-wing targets for 5♥-6♠-7♥. Guards against collapsing them by value+suit alone.
  op: wings_for_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
    at (300,200): 2♣' 3♦' 4♣'
    at (500,200): 5♥ 6♠ 7♥
  source:
    at (500,200): 5♥ 6♠ 7♥
  expect_wings:
    - target: 2♣ 3♦ 4♣
      side: Right
    - target: 2♣' 3♦' 4♣'
      side: Right
