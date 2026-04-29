# Board geometry conformance scenarios (validate_board_geometry +
# classify_board_geometry + stack_height_constant). Ported from
# games/lynrummy/elm/tests/Game/BoardGeometryTest.elm.
#
# All 15 source tests ported. Python has no equivalent of the
# typed-error API (validateBoardGeometry / classifyBoardGeometry);
# it has the simpler find_violation / out_of_bounds helpers.
# These are Elm-only conformance tests (Python: false).
#
# Layout constants (match Game.CardStack + Game.Physics.BoardGeometry):
#   cardWidth  = 27
#   cardPitch  = 33   (cardWidth + 6)
#   cardHeight = 40
#   stackWidth(n) = 27 + (n-1) * 33
#   stackWidth(3) = 93   stackWidth(5) = 159
#   bounds: maxWidth=800 maxHeight=600 margin=7


scenario board_geometry_empty_board
  desc: Empty board has no errors.
  op: validate_board_geometry
  board:
  expect: ok


scenario board_geometry_single_stack_valid
  desc: Single stack within bounds is valid.
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC
  expect: ok


scenario board_geometry_two_non_overlapping_valid
  desc: Two non-overlapping stacks (different rows) are valid.
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC
    at (100,10): AC AC AC AC
  expect: ok


scenario board_geometry_side_by_side_with_margin_valid
  desc: Side-by-side stacks with exactly margin+1 gap are valid. left2 = 10 + stackWidth(3) + margin + 1 = 10+93+7+1 = 111.
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC
    at (10,111): AC AC AC
  expect: ok


scenario board_geometry_out_of_bounds_right
  desc: Stack extends past the right edge. left=780, stackWidth(3)=93, right=873 > 800.
  op: validate_board_geometry
  board:
    at (10,780): AC AC AC
  expect: error
    error_count: 1
    any_error_kind: out_of_bounds


scenario board_geometry_out_of_bounds_bottom
  desc: Stack extends past the bottom edge. top=570, cardHeight=40, bottom=610 > 600.
  op: validate_board_geometry
  board:
    at (570,10): AC AC AC
  expect: error
    error_count: 1
    any_error_kind: out_of_bounds


scenario board_geometry_out_of_bounds_negative_x
  desc: Stack at negative left is out of bounds.
  op: validate_board_geometry
  board:
    at (10,-5): AC AC AC
  expect: error
    error_count: 1
    any_error_kind: out_of_bounds


scenario board_geometry_identical_positions_overlap
  desc: Two stacks at identical positions produce an Overlap error.
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC
    at (10,10): AC AC AC
  expect: error
    any_error_kind: overlap


scenario board_geometry_horizontal_partial_overlap
  desc: Two 5-card stacks horizontally overlapping. Stack 0 right=169, stack 1 left=50. stackWidth(5)=159.
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC AC AC
    at (10,50): AC AC AC AC AC
  expect: error
    any_error_kind: overlap


scenario board_geometry_too_close_not_overlap
  desc: Stacks within margin but not overlapping produce TooClose, not Overlap. left2 = 10+93+7-1 = 109.
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC
    at (10,109): AC AC AC
  expect: error
    any_error_kind: too_close
    no_error_kind: overlap


scenario board_geometry_three_stacks_only_overlapping_pair
  desc: Stacks 0 and 2 overlap; stack 1 is clean. Exactly one Overlap error with stackIndices [0,2].
  op: validate_board_geometry
  board:
    at (10,10): AC AC AC
    at (100,10): AC AC AC
    at (10,10): AC AC AC
  expect: error
    overlap_count: 1
    overlap_stack_indices: 0 2


scenario board_geometry_classify_cleanly_spaced
  desc: Two well-spaced stacks classify as CleanlySpaced.
  op: classify_board_geometry
  board:
    at (10,10): AC AC AC
    at (100,10): AC AC AC
  expect:
    geometry_status: CleanlySpaced


scenario board_geometry_classify_crowded
  desc: Two stacks within margin but not overlapping classify as Crowded. left2 = 10+93+1 = 104.
  op: classify_board_geometry
  board:
    at (10,10): AC AC AC
    at (10,104): AC AC AC
  expect:
    geometry_status: Crowded


scenario board_geometry_classify_illegal_overlap
  desc: Two stacks at the same position classify as Illegal.
  op: classify_board_geometry
  board:
    at (10,10): AC AC AC
    at (10,10): AC AC AC
  expect:
    geometry_status: Illegal


scenario board_geometry_classify_illegal_out_of_bounds
  desc: Stack extending past right edge classifies as Illegal. left=790, stackWidth(3)=93, right=883 > 800.
  op: classify_board_geometry
  board:
    at (10,790): AC AC AC
  expect:
    geometry_status: Illegal


scenario board_geometry_stack_height_is_40
  desc: stackHeight is a constant 40.
  op: stack_height_constant
  expect: stack_height_40
