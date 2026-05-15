# Drag-invariant conformance scenarios (floater_top_left).
#
# Invariants under test:
#   - shift_equals_delta — floater shifts by exactly the cursor
#     delta on mousemove, regardless of where on the card the
#     user grabbed. Eliminates grabOffset from the update path.
#   - grab_point_invariant — two distinct grab points produce
#     the same floater shift for the same delta.
#   - initial_floater_at — after mousedown on a board-card, the
#     drag's `floaterTopLeft` equals the source stack's `loc`
#     in board frame.
#
# Layout note: stackAt "2♣,3♦,4♣" (at left=100 top=200) means
# the stack's loc = { left=100, top=200 }.  In DSL board notation
# that is `at (100,200)` (top first, left second).
#
# Cursor points use (x, y) — x is horizontal, y is vertical.


scenario drag_invariant_floater_shift
  desc: floaterTopLeft shifts by exactly the cursor delta (mousedown to mousemove).
  op: floater_top_left
  board:
    at (100,200): 2♣ 3♦ 4♣
  card_index: 2
  mousedown: (540, 310)
  mousemove_delta: (20, -5)
  expect:
    shift_equals_delta: true


scenario drag_invariant_grab_point_invariant
  desc: Two different grab points produce the same floater shift for the same delta.
  op: floater_top_left
  board:
    at (100,200): 2♣ 3♦ 4♣
  mousedown_a: (410, 310)
  mousedown_b: (500, 320)
  delta: (15, 8)
  expect:
    grab_point_invariant: true


scenario drag_invariant_board_drag_initial_floater
  desc: intra-board drag initial floaterTopLeft equals stack.loc in board frame.
  op: floater_top_left
  board:
    at (100,200): 2♣ 3♦ 4♣
  card_index: 0
  mousedown: (410, 310)
  expect:
    initial_floater_at: (100, 200)
