# Layout note: board/target blocks use `at (top, left): cards`
# (top first, left second). The `floater_at:` and `cursor:` scalars
# use `(x, y)` where x=horizontal (left), y=vertical (top).
#
# defaultBoardRect used by MoveStack/PlaceHand: { x=300, y=100, width=800, height=600 }.
# Cursor (700, 400) is inside that rect; used as a stand-in cursor
# for scenarios where the cursor is over the board but its exact
# position does not affect the result.


scenario gesture_split_surviving_click_intent
  desc: board-stack source with surviving clickIntent yields Split.
  op: gesture_split
  board:
    at (20,20): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  floater_at: (20, 20)
  gesture_click_intent: 3
  expect:
    card_index: 3


scenario gesture_merge_stack_234_onto_567_left
  desc: source 234 dragged onto 567's left wing yields MergeStack side=Left.
  op: gesture_merge_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
  target:
    at (300,200): 5♥ 6♠ 7♥
  floater_at: (207, 200)
  hovered_side: Left
  expect:
    side: Left


scenario gesture_merge_stack_567_onto_234_right
  desc: source 567 dragged onto 234's right wing yields MergeStack side=Right.
  op: gesture_merge_stack
  board:
    at (300,200): 5♥ 6♠ 7♥
  target:
    at (100,200): 2♣ 3♦ 4♣
  floater_at: (193, 200)
  hovered_side: Right
  expect:
    side: Right


scenario gesture_merge_hand_card_onto_board_wing
  desc: hand-card drop onto a board stack's right wing yields MergeHand.
  op: gesture_merge_hand
  hand_card: 6♥
  target:
    at (100,200): 3♣ 4♦ 5♣
  floater_at: (499, 300)
  hovered_side: Right
  expect:
    side: Right


scenario gesture_move_stack_valid_drop
  desc: board-stack drag with cursor over board and in-bounds floater yields MoveStack.
  op: gesture_move_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
  floater_at: (400, 300)
  cursor: (700, 400)
  expect:
    new_loc_left: 400
    new_loc_top: 300


scenario gesture_move_stack_off_board_rejected
  desc: board-stack drag whose floater lands at negative board-frame coords is rejected (Nothing).
  op: gesture_move_stack
  board:
    at (100,200): 2♣ 3♦ 4♣
  floater_at: (-50, -20)
  cursor: (700, 400)
  expect:
    rejected: true


scenario gesture_place_hand_drops_to_board
  desc: hand-card drag with cursor over board yields PlaceHand with board-frame loc.
  op: gesture_place_hand
  hand_card: 6♥
  floater_at: (750, 450)
  cursor: (750, 450)
  expect:
    loc_left: 450
    loc_top: 350


scenario gesture_floater_over_wing_right_fires
  desc: floater exactly on right-wing landing fires.
  op: gesture_floater_over_wing
  board:
    at (20,20): 2♣ 3♦ 4♣
  target:
    at (300,20): 5♥ 6♠ 7♥
  floater_at: (399, 20)
  hovered_side: Right
  expect:
    has_wing: true
    side: Right


scenario gesture_floater_over_wing_left_fires
  desc: floater exactly on left-wing landing fires.
  op: gesture_floater_over_wing
  board:
    at (20,20): 2♣ 3♦ 4♣
  target:
    at (300,20): 5♥ 6♠ 7♥
  floater_at: (201, 20)
  hovered_side: Left
  expect:
    has_wing: true
    side: Left


scenario gesture_floater_over_wing_past_tolerance
  desc: floater past one pitch from right-wing landing does NOT fire.
  op: gesture_floater_over_wing
  board:
    at (20,20): 2♣ 3♦ 4♣
  target:
    at (300,20): 5♥ 6♠ 7♥
  floater_at: (437, 20)
  hovered_side: Right
  expect:
    has_wing: false


scenario gesture_floater_over_wing_way_off
  desc: floater far from any wing returns Nothing.
  op: gesture_floater_over_wing
  board:
    at (20,20): 2♣ 3♦ 4♣
  target:
    at (300,20): 5♥ 6♠ 7♥
  floater_at: (50, 400)
  hovered_side: Right
  expect:
    has_wing: false
