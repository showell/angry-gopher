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

# --- hint_invariant: "apply the trick's emission, assert the
#     resulting board has no incomplete stacks" ---

scenario hint_invariant_direct_play_extend_pure_run
  desc: direct_play extends a 3-card pure diamond run by one card. Single primitive, clean board.
  op: hint_invariant
  trick: direct_play
  hand: 9D'
  board:
    at (40,40):  6D 7D 8D
    at (180,40): AC 2C 3C
  expect: invariant_holds

scenario hint_invariant_direct_play_complete_set
  desc: direct_play completes a 3-card set by landing the fourth suit. Single primitive.
  op: hint_invariant
  trick: direct_play
  hand: 5D'
  board:
    at (40,40): 5H 5C 5S
  expect: invariant_holds

scenario hint_invariant_hand_stacks_set_three_of_a_kind
  desc: hand_stacks places three same-value hand cards as a brand-new set stack.
  op: hint_invariant
  trick: hand_stacks
  hand: 4H' 4S' 4D'
  board:
    at (40,40): JC QC KC
  expect: invariant_holds

scenario hint_invariant_hand_stacks_pure_run_three_card
  desc: hand_stacks places a 3-card pure-run group from the hand as a new stack.
  op: hint_invariant
  trick: hand_stacks
  hand: 5H' 6H' 7H'
  board:
    at (40,40): JC QC KC
  expect: invariant_holds

scenario hint_invariant_hand_stacks_rb_run_three_card
  desc: hand_stacks places a 3-card red-black run from the hand as a new stack.
  op: hint_invariant
  trick: hand_stacks
  hand: 5H' 6C' 7H'
  board:
    at (40,40): JC QC KC
  expect: invariant_holds

scenario hint_invariant_pair_peel_set_pair_edge
  desc: pair_peel peels the 5D off the edge of a 4-run, then merges all three 5s as a new set.
  op: hint_invariant
  trick: pair_peel
  hand: 5H' 5S'
  board:
    at (40,40): 5D 6D 7D 8D
  expect: invariant_holds

scenario hint_invariant_pair_peel_run_pair_pure_edge
  desc: pair_peel peels from a 4-card pure run and forms a new pure run from the hand + peeled card. Order matters — closer-value hand card merges first.
  op: hint_invariant
  trick: pair_peel
  hand: 5H' 6H'
  board:
    at (40,40): 7H 8H 9H TH
  expect: invariant_holds

scenario hint_invariant_pair_peel_set_pair_middle
  desc: pair_peel middle-peels the 5D out of an 8-card run; both remnants plus the hand-card set must all stay complete.
  op: hint_invariant
  trick: pair_peel
  hand: 5H' 5S'
  board:
    at (40,40): 2D 3D 4D 5D 6D 7D 8D 9D
  expect: invariant_holds

scenario hint_invariant_split_for_set_both_edges
  desc: split_for_set peels the 5D off one 4-run and the 5S off another, merges with the 5H hand card. Both remnants stay clean.
  op: hint_invariant
  trick: split_for_set
  hand: 5H'
  board:
    at (40,40):  5D 6D 7D 8D
    at (40,300): 5S 6S 7S 8S
  expect: invariant_holds

scenario hint_invariant_split_for_set_one_middle_one_edge
  desc: split_for_set extracts 5D from the middle of an 8-run and 5S from the edge of a 4-run. Middle-peel leaves two valid remnants.
  op: hint_invariant
  trick: split_for_set
  hand: 5H'
  board:
    at (40,40):  2D 3D 4D 5D 6D 7D 8D 9D
    at (40,400): 5S 6S 7S 8S
  expect: invariant_holds

scenario hint_invariant_peel_for_run_rb_edges
  desc: peel_for_run peels two clubs off separate runs, then merges them with the TD hand card into a red-black [9C,TD,JC] run. Edge-peels only.
  op: hint_invariant
  trick: peel_for_run
  hand: TD'
  board:
    at (40,40):  6C 7C 8C 9C
    at (40,300): JC QC KC AC
  expect: invariant_holds

scenario hint_invariant_rb_swap_middle_swap_clubs_home
  desc: rb_swap finds an rb-run [3D,4C,5D,6C] with 4C swappable; hand 4S replaces 4C, which goes home to the clubs pure run.
  op: hint_invariant
  trick: rb_swap
  hand: 4S'
  board:
    at (40,40):  3D 4C 5D 6C
    at (40,300): AC 2C 3C
    at (180,40): 9H TH JH
  expect: invariant_holds
