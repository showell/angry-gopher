# Trick/hint conformance scenarios. Each test pins down the
# exact ranked output of `BuildSuggestions(hand, board)` across
# Go and Elm implementations. Regenerate after edits:
#
#   go run ./cmd/fixturegen ./games/lynrummy/conformance/scenarios/*.dsl

scenario hint_empty_hand_no_suggestions
  desc: An empty hand produces no suggestions regardless of board state.
  op: build_suggestions
  board:
    at (70,20): KS AS 2S 3S
    at (160,80): TD JD QD KD
    at (100,140): 2H 3H 4H
  expect: suggestions

scenario hint_direct_play_wins_priority_on_opening_board
  desc: With a hand that contains 7H', the opening board admits a direct_play (7H' onto the 7-set). Priority order means direct_play ranks first; other tricks may follow.
  op: build_suggestions
  hand: 7H'
  board:
    at (70,20): KS AS 2S 3S
    at (160,80): TD JD QD KD
    at (100,140): 2H 3H 4H
    at (40,200): 7S 7D 7C
    at (130,260): AC AD AH
    at (70,320): 2C 3D 4C 5H 6S 7H
  expect: suggestions
    suggestion: direct_play, 7H'

scenario hint_no_plays_for_lonely_unplayable_card
  desc: A hand that can't extend anything on this board yields no suggestions at all. 9S doesn't extend the short heart run or the 7-set, and there's no other trick geometry available.
  op: build_suggestions
  hand: 9S
  board:
    at (70,20): 2H 3H 4H
  expect: suggestions
