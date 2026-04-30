# Click-arbitration conformance scenarios.
# Ported from games/lynrummy/elm/tests/Game/GestureArbitrationTest.elm
# — the `clickIntentAfterMove` describe block (8 tests, lines 45–85).
#
# Rule: distSquared(mousedown, current) > 9 kills click intent permanently.
# Once Nothing, always Nothing for the rest of the gesture.
#
# All ops are Elm-only (no Python gesture layer).


scenario click_intent_nothing_in_nothing_out_zero_distance
  desc: Nothing in stays Nothing out even at zero movement.
  op: click_arbitration
  mousedown: (0, 0)
  current: (0, 0)
  expect_click_intent: nothing


scenario click_intent_nothing_in_nothing_out_large_distance
  desc: Nothing in stays Nothing out even at large movement (death was already permanent).
  op: click_arbitration
  mousedown: (0, 0)
  current: (100, 100)
  expect_click_intent: nothing


scenario click_intent_just_survives_zero_movement
  desc: Just survives when cursor has not moved at all.
  op: click_arbitration
  mousedown: (5, 5)
  current: (5, 5)
  initial_click_intent: 2
  expect_click_intent: 2


scenario click_intent_just_survives_axis_jitter_3px
  desc: Just survives axis jitter up to 3 px (distSquared=9, NOT > threshold).
  op: click_arbitration
  mousedown: (0, 0)
  current: (3, 0)
  initial_click_intent: 2
  expect_click_intent: 2


scenario click_intent_just_survives_small_diagonal_jitter
  desc: Just survives small diagonal jitter (2,2) (distSquared=8).
  op: click_arbitration
  mousedown: (0, 0)
  current: (2, 2)
  initial_click_intent: 2
  expect_click_intent: 2


scenario click_intent_just_dies_past_threshold
  desc: Just dies past threshold (4,0) (distSquared=16 > 9).
  op: click_arbitration
  mousedown: (0, 0)
  current: (4, 0)
  initial_click_intent: 2
  expect_click_intent: nothing


scenario click_intent_just_dies_large_movement
  desc: Just dies at large movement.
  op: click_arbitration
  mousedown: (0, 0)
  current: (50, 50)
  initial_click_intent: 2
  expect_click_intent: nothing


scenario click_intent_death_is_permanent
  desc: Death is permanent — after killing intent at (50,50), returning to origin still yields Nothing.
  op: click_arbitration
  mousedown: (0, 0)
  pre_kill_at: (50, 50)
  initial_click_intent: 2
  current: (0, 0)
  expect_click_intent: nothing
