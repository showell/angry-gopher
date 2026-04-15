# LynRummy trick scenarios (trick_first_play).
# Compiled to native Go + Elm tests by cmd/fixturegen.

scenario direct_play_right_extend_heart_run
  desc: Hand 8H extends a 5H-6H-7H pure run at the right end.
  op: trick_first_play
  trick: direct_play
  hand: 8H
  board:
    at (10,10): 5H 6H 7H
  expect: play
    hand_played: 8H
    board_after:
      at (10,10): 5H 6H 7H 8H*

scenario direct_play_left_extend_heart_run
  desc: Hand 2H extends a 3H-4H-5H run at the left end. Stack loc shifts left by CardWidth+6 (=33).
  op: trick_first_play
  trick: direct_play
  hand: 2H
  board:
    at (10,200): 3H 4H 5H
  expect: play
    hand_played: 2H
    board_after:
      at (10,167): 2H* 3H 4H 5H

scenario direct_play_extends_loose_card
  desc: Hand 6H right-extends a loose 1-card 5H stack to a 2-card Incomplete — regression guard for maybeMerge.
  op: trick_first_play
  trick: direct_play
  hand: 6H
  board:
    at (10,50): 5H
  expect: play
    hand_played: 6H
    board_after:
      at (10,50): 5H 6H*

scenario direct_play_no_plays
  desc: Hand 9D cannot extend any existing stack.
  op: trick_first_play
  trick: direct_play
  hand: 9D
  board:
    at (10,10): 5H 6H 7H
  expect: no_plays

scenario hand_stacks_pure_run
  desc: Hand 2C-3C-4C pushed as a new stack at DUMMY_LOC.
  op: trick_first_play
  trick: hand_stacks
  hand: 2C 3C 4C
  board:
    at (10,10): AH 2H 3H
  expect: play
    hand_played: 2C 3C 4C
    board_after:
      at (10,10): AH 2H 3H
      at (0,0): 2C* 3C* 4C*

scenario hand_stacks_set
  desc: Hand 7H-7S-7D pushed as a new 3-set.
  op: trick_first_play
  trick: hand_stacks
  hand: 7H 7S 7D
  board:
  expect: play
    hand_played: 7H 7S 7D
    board_after:
      at (0,0): 7H* 7S* 7D*

scenario hand_stacks_no_plays
  desc: Hand has no 3+ group forming a set or run.
  op: trick_first_play
  trick: hand_stacks
  hand: 7H 2D
  board:
  expect: no_plays

scenario split_for_set_eights
  desc: Hand 8H; pull 8S + 8D off two size-4 pure runs; new 3-set of 8s.
  op: trick_first_play
  trick: split_for_set
  hand: 8H
  board:
    at (10,10): 5S 6S 7S 8S
    at (10,200): 5D 6D 7D 8D
  expect: play
    hand_played: 8H
    board_after:
      at (10,10): 5S 6S 7S
      at (10,200): 5D 6D 7D
      at (0,0): 8H* 8S 8D

scenario split_for_set_no_plays
  desc: Hand 8H finds no same-value extractable board cards.
  op: trick_first_play
  trick: split_for_set
  hand: 8H
  board:
    at (10,10): AH 2H 3H
  expect: no_plays

scenario peel_for_run_rb_triple
  desc: Hand 5H; peel 4S + 6S off two 4-sets; new rb run [4S, 5H, 6S].
  op: trick_first_play
  trick: peel_for_run
  hand: 5H
  board:
    at (10,10): 4S 4C 4D 4H
    at (10,200): 6S 6C 6D 6H
  expect: play
    hand_played: 5H
    board_after:
      at (10,10): 4C 4D 4H
      at (10,200): 6C 6D 6H
      at (0,0): 4S 5H* 6S

scenario rb_swap_5D_into_rb_run
  desc: Hand 5D swaps into an rb run at the 5H seat; kicked 5H extends a pure hearts run.
  op: trick_first_play
  trick: rb_swap
  hand: 5D
  board:
    at (10,10): 5H 6S 7H 8S
    at (10,200): 2H 3H 4H
  expect: play
    hand_played: 5D
    board_after:
      at (10,10): 5D* 6S 7H 8S
      at (10,200): 2H 3H 4H 5H*

scenario pair_peel_rb_from_pure_run
  desc: Hand JS+QH (rb pair); peel TD off a pure diamond run to complete [TD, JS, QH] rb run.
  op: trick_first_play
  trick: pair_peel
  hand: JS QH
  board:
    at (10,10): TD JD QD KD
  expect: play
    hand_played: JS QH
    board_after:
      at (10,10): JD QD KD
      at (0,0): TD JS* QH*

scenario loose_card_play_7H_to_heart_run
  desc: Hand 8H is stranded. Peel 7H off a 4-set onto [4H,5H,6H]; 8H then extends.
  op: trick_first_play
  trick: loose_card_play
  hand: 8H
  board:
    at (10,10): 4H 5H 6H
    at (10,200): 7S 7C 7D 7H
  expect: play
    hand_played: 8H
    board_after:
      at (10,10): 4H 5H 6H 7H* 8H*
      at (10,200): 7S 7C 7D
