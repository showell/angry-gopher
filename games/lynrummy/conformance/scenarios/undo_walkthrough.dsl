# Narrative walkthrough for the Undo feature.
#
# Each scenario reads like a game transcript: the player takes
# a couple of actions, then undoes them one at a time.  After
# each step the DSL asserts board count, undo-button state,
# and (where relevant) specific stack content and hand cards.
# expect_final_board shows the complete board after all steps.

scenario undo_walkthrough_split_then_move
  desc: Player splits a run, slides a piece, then undoes both moves one by one.
  op: undo_walkthrough
  board:
    at (20,70): KS AS 2S 3S
    at (80,160): TD JD QD KD
    at (140,100): 2H 3H 4H
    at (200,40): 7S 7D 7C
    at (260,130): AC AD AH
    at (320,70): 2C 3D 4C 5H 6S 7H
  steps:
    - step: board starts with six stacks, nothing to undo yet
      expect_board_count: 6
      expect_undoable: false
    - step: player splits the KS-AS-2S-3S run at the midpoint
      action: split [KS AS 2S 3S]@2
      expect_board_count: 7
      expect_undoable: true
    - step: player slides the 2S-3S piece to a new spot
      action: move_stack [2S 3S] -> (400, 300)
      expect_board_count: 7
      expect_undoable: true
    - step: player undoes the slide — piece snaps back to split position
      action: undo
      expect_board_count: 7
      expect_undoable: true
    - step: player undoes the split — KS-AS-2S-3S run is whole again
      action: undo
      expect_board_count: 6
      expect_undoable: false
      expect_stack: KS AS 2S 3S
  expect_final_board:
    at (20,70): KS AS 2S 3S
    at (80,160): TD JD QD KD
    at (140,100): 2H 3H 4H
    at (200,40): 7S 7D 7C
    at (260,130): AC AD AH
    at (320,70): 2C 3D 4C 5H 6S 7H

scenario undo_walkthrough_merge_hand
  desc: Player merges a hand card onto a set, then undoes — card returns to hand.
  op: undo_walkthrough
  hand: 7H'
  board:
    at (20,70): KS AS 2S 3S
    at (80,160): TD JD QD KD
    at (140,100): 2H 3H 4H
    at (200,40): 7S 7D 7C
    at (260,130): AC AD AH
    at (320,70): 2C 3D 4C 5H 6S 7H
  steps:
    - step: one card in hand, six stacks on board, nothing to undo
      expect_board_count: 6
      expect_hand_count: 1
      expect_undoable: false
    - step: player merges 7H' from hand onto the 7S-7D-7C set on the right
      action: merge_hand 7H' -> [7S 7D 7C] /right
      expect_board_count: 6
      expect_hand_count: 0
      expect_undoable: true
      expect_stack: 7S 7D 7C 7H'
    - step: player undoes the merge — 7H' returns to hand, set shrinks back
      action: undo
      expect_board_count: 6
      expect_hand_count: 1
      expect_undoable: false
      expect_stack: 7S 7D 7C
      expect_hand_contains: 7H'
  expect_final_board:
    at (20,70): KS AS 2S 3S
    at (80,160): TD JD QD KD
    at (140,100): 2H 3H 4H
    at (200,40): 7S 7D 7C
    at (260,130): AC AD AH
    at (320,70): 2C 3D 4C 5H 6S 7H
