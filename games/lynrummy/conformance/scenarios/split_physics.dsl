# Split-physics conformance — both languages produce.
#
# Each scenario specifies (a) a single input stack at a loc with
# its cards, (b) a `left_count` for the split, (c) the two
# expected post-split pieces with their pixel positions. Both
# the TS implementation (`ts/game_events/primitives.ts:applySplit`)
# and the Elm implementation (`Lib.CardStack.split`) run against
# the same input and must produce the same output.
#
# The rule under test (Steve, 2026-05-19):
#   - The smaller chunk nudges up by 4; on a tie the right chunk
#     wins.
#   - Both pieces slide out from the cut line: left by 2 to the
#     left of the original loc; right by 2 to the right of where
#     it would have naturally sat (`originalLeft + leftCount * 33`).
#
# Coordinate format `(left,top)` (left first).


# --- 2-card stacks (tie) ----------------------------------------

scenario split_n2_leftcount_1_at_50_50
  desc: Length-2 split — tie on chunk size, right wins; nudges up by 4.
  op: split_physics
  board:
    at (50,50): A♠ 2♠
  left_count: 1
  expect_left:
    at (48,50): A♠
  expect_right:
    at (85,46): 2♠


# --- 3-card stacks ----------------------------------------------

scenario split_n3_leftcount_1_at_70_20
  desc: 3-card stack, left singleton smaller → left up.
  op: split_physics
  board:
    at (70,20): 2♣ 3♦ 4♣
  left_count: 1
  expect_left:
    at (68,16): 2♣
  expect_right:
    at (105,20): 3♦ 4♣

scenario split_n3_leftcount_2_at_70_20
  desc: 3-card stack, right singleton smaller → right up.
  op: split_physics
  board:
    at (70,20): 2♣ 3♦ 4♣
  left_count: 2
  expect_left:
    at (68,20): 2♣ 3♦
  expect_right:
    at (138,16): 4♣


# --- 4-card stacks (boundary case at leftCount=2) ---------------

scenario split_n4_leftcount_1_at_70_20
  desc: 4-card stack, left singleton smallest → left up.
  op: split_physics
  board:
    at (70,20): 2♣ 3♦ 4♣ 5♥
  left_count: 1
  expect_left:
    at (68,16): 2♣
  expect_right:
    at (105,20): 3♦ 4♣ 5♥

scenario split_n4_leftcount_2_at_70_20
  desc: 4-card stack, tied chunks (2/2) → right up by tie rule.
  op: split_physics
  board:
    at (70,20): 2♣ 3♦ 4♣ 5♥
  left_count: 2
  expect_left:
    at (68,20): 2♣ 3♦
  expect_right:
    at (138,16): 4♣ 5♥

scenario split_n4_leftcount_3_at_70_20
  desc: 4-card stack, right singleton smallest → right up.
  op: split_physics
  board:
    at (70,20): 2♣ 3♦ 4♣ 5♥
  left_count: 3
  expect_left:
    at (68,20): 2♣ 3♦ 4♣
  expect_right:
    at (171,16): 5♥


# --- 5-card stacks (odd, no tie possible) -----------------------

scenario split_n5_leftcount_2_at_100_100
  desc: 5-card stack, leftCount=2 → left smaller → left up.
  op: split_physics
  board:
    at (100,100): 2♣ 3♦ 4♣ 5♥ 6♠
  left_count: 2
  expect_left:
    at (98,96): 2♣ 3♦
  expect_right:
    at (168,100): 4♣ 5♥ 6♠

scenario split_n5_leftcount_3_at_100_100
  desc: 5-card stack, leftCount=3 → right smaller → right up.
  op: split_physics
  board:
    at (100,100): 2♣ 3♦ 4♣ 5♥ 6♠
  left_count: 3
  expect_left:
    at (98,100): 2♣ 3♦ 4♣
  expect_right:
    at (201,96): 5♥ 6♠


# --- 6-card stack (boundary case at leftCount=3) ----------------

scenario split_n6_leftcount_3_at_20_20
  desc: 6-card stack, tied chunks (3/3) — Steve's repro case. Click on 5 in [2-7] → leftCount=3 → tie → [5,6,7] (right) nudges up.
  op: split_physics
  board:
    at (20,20): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  left_count: 3
  expect_left:
    at (18,20): 2♣ 3♦ 4♣
  expect_right:
    at (121,16): 5♥ 6♠ 7♥


# --- off-origin stack loc (catches offset arithmetic) -----------

scenario split_n4_leftcount_2_at_187_257
  desc: Tied split at a non-trivial board loc — catches drift in the `leftCount * stackPitch` arithmetic.
  op: split_physics
  board:
    at (187,257): 3♣ 4♦ 5♠ 6♦
  left_count: 2
  expect_left:
    at (185,257): 3♣ 4♦
  expect_right:
    at (255,253): 5♠ 6♦


# --- deck-2 cards (apostrophe propagation) ----------------------

scenario split_n4_leftcount_1_deck2_cards
  desc: Cards with deck-2 apostrophes survive the round-trip on both sides.
  op: split_physics
  board:
    at (100,100): 2♣' 3♦' 4♣' 5♥'
  left_count: 1
  expect_left:
    at (98,96): 2♣'
  expect_right:
    at (135,100): 3♦' 4♣' 5♥'


# --- 7-card stack (right-smaller, larger arithmetic) ------------

scenario split_n7_leftcount_4_at_100_100
  desc: 7-card stack, leftCount=4 → right (3) smaller → right up. Larger stack catches any size-dependent regression.
  op: split_physics
  board:
    at (100,100): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥ 8♣
  left_count: 4
  expect_left:
    at (98,100): 2♣ 3♦ 4♣ 5♥
  expect_right:
    at (234,96): 6♠ 7♥ 8♣
