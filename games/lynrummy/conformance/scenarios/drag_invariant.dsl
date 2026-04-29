# Drag-invariant conformance scenarios (floater_top_left + path_frame).
# Ported from games/lynrummy/elm/tests/Main/DragInvariantTest.elm.
#
# All 5 source tests ported. These are Elm-only (no Python drag
# layer); Python: false for both ops.
#
# Two invariants under test:
#   1. floater_top_left — floater shifts by exactly the cursor delta
#      on mousemove, regardless of where on the card the user grabbed.
#      This is the invariant that eliminates grabOffset from the
#      update path.
#   2. path_frame — mousedown sets BoardFrame for intra-board drags,
#      ViewportFrame for hand-origin drags.
#
# Layout note: stackAt "2C,3D,4C" (at left=100 top=200) means
# the stack's loc = { left=100, top=200 }.  In DSL board notation
# that is `at (200, 100)` (top first, left second).
#
# Cursor points use (x, y) — x is horizontal, y is vertical.


scenario drag_invariant_floater_shift
  desc: floaterTopLeft shifts by exactly the cursor delta (mousedown to mousemove).
  op: floater_top_left
  board:
    at (200, 100): 2C 3D 4C
  card_index: 2
  mousedown: (540, 310)
  mousemove_delta: (20, -5)
  expect:
    shift_equals_delta: true


scenario drag_invariant_grab_point_invariant
  desc: Two different grab points produce the same floater shift for the same delta.
  op: floater_top_left
  board:
    at (200, 100): 2C 3D 4C
  mousedown_a: (410, 310)
  mousedown_b: (500, 320)
  delta: (15, 8)
  expect:
    grab_point_invariant: true


scenario drag_invariant_board_drag_path_frame
  desc: intra-board mousedown sets pathFrame = BoardFrame.
  op: path_frame
  board:
    at (200, 100): 2C 3D 4C
  card_index: 0
  mousedown: (410, 310)
  expect:
    frame: BoardFrame


scenario drag_invariant_hand_drag_path_frame
  desc: hand-origin mousedown sets pathFrame = ViewportFrame.
  op: path_frame
  hand_card: 6H
  mousedown: (50, 120)
  expect:
    frame: ViewportFrame


scenario drag_invariant_board_drag_initial_floater
  desc: intra-board drag initial floaterTopLeft equals stack.loc in board frame.
  op: path_frame
  board:
    at (200, 100): 2C 3D 4C
  card_index: 0
  mousedown: (410, 310)
  expect:
    initial_floater_at: (100, 200)
