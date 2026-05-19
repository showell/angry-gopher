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
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  steps:
    step_1:
      desc: board starts with six stacks, nothing to undo yet
      expect_board_count: 6
      expect_undoable: false
    step_2:
      desc: player splits the K♠-A♠-2♠-3♠ run at the midpoint
      action: split K♠ A♠ / 2♠ 3♠
      expect_board_count: 7
      expect_undoable: true
    step_3:
      desc: player slides the 2♠-3♠ piece to a new spot
      action: move_stack [2♠ 3♠] -> (300,400)
      expect_board_count: 7
      expect_undoable: true
    step_4:
      desc: player undoes the slide — piece snaps back to split position
      action: undo
      expect_board_count: 7
      expect_undoable: true
    step_5:
      desc: player undoes the split — K♠-A♠-2♠-3♠ run is whole again
      action: undo
      expect_board_count: 6
      expect_undoable: false
      expect_stack: K♠ A♠ 2♠ 3♠
  expect_final_board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥

scenario undo_walkthrough_merge_hand
  desc: Player merges a hand card onto a set, then undoes — card returns to hand.
  op: undo_walkthrough
  hand: 7♥'
  board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  steps:
    step_1:
      desc: one card in hand, six stacks on board, nothing to undo
      expect_board_count: 6
      expect_hand_count: 1
      expect_undoable: false
    step_2:
      desc: player merges 7♥' from hand onto the 7♠-7♦-7♣ set on the right
      action: merge_hand 7♥' -> [7♠ 7♦ 7♣] /right
      expect_board_count: 6
      expect_hand_count: 0
      expect_undoable: true
      expect_stack: 7♠ 7♦ 7♣ 7♥'
    step_3:
      desc: player undoes the merge — 7♥' returns to hand, set shrinks back
      action: undo
      expect_board_count: 6
      expect_hand_count: 1
      expect_undoable: false
      expect_stack: 7♠ 7♦ 7♣
      expect_hand_contains: 7♥'
  expect_final_board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥

scenario undo_walkthrough_merge_stack
  desc: Player merges two board runs, then undoes — both original stacks are restored.
  op: undo_walkthrough
  board:
    at (70,20): 4♥ 5♥ 6♥
    at (160,80): 7♥ 8♥ 9♥
  steps:
    step_1:
      desc: two stacks on board, nothing to undo
      expect_board_count: 2
      expect_undoable: false
    step_2:
      desc: player merges 7♥-8♥-9♥ onto the right of 4♥-5♥-6♥
      action: merge_stack [7♥ 8♥ 9♥] -> [4♥ 5♥ 6♥] /right
      expect_board_count: 1
      expect_undoable: true
      expect_stack: 4♥ 5♥ 6♥ 7♥ 8♥ 9♥
    step_3:
      desc: player undoes the merge — both original stacks reappear; source is back
      action: undo
      expect_board_count: 2
      expect_undoable: false
      expect_stack: 7♥ 8♥ 9♥
    step_4:
      desc: target is back too
      expect_board_count: 2
      expect_stack: 4♥ 5♥ 6♥
  expect_final_board:
    at (70,20): 4♥ 5♥ 6♥
    at (160,80): 7♥ 8♥ 9♥

scenario undo_walkthrough_place_hand
  desc: Player places a hand card onto the board, then undoes — card returns to hand.
  op: undo_walkthrough
  hand: 7♥'
  board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  steps:
    step_1:
      desc: one card in hand, six stacks on board, nothing to undo
      expect_board_count: 6
      expect_hand_count: 1
      expect_undoable: false
    step_2:
      desc: player places 7♥' from hand onto an open board location
      action: place_hand 7♥' -> (300,400)
      expect_board_count: 7
      expect_hand_count: 0
      expect_undoable: true
    step_3:
      desc: player undoes the place — 7♥' returns to hand, board shrinks back
      action: undo
      expect_board_count: 6
      expect_hand_count: 1
      expect_undoable: false
      expect_hand_contains: 7♥'
  expect_final_board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥

scenario undo_restores_position
  desc: Undo of a move restores the stack to its exact original position, not just its card content.
  op: undo_walkthrough
  board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
  steps:
    step_1:
      desc: board has two stacks at their initial positions
      expect_board_count: 2
      expect_undoable: false
    step_2:
      desc: player moves K♠-A♠-2♠-3♠ to a new location
      action: move_stack [K♠ A♠ 2♠ 3♠] -> (300,400)
      expect_board_count: 2
      expect_undoable: true
      expect_loc: (300,400)
    step_3:
      desc: player undoes the move — stack snaps back to exact original position
      action: undo
      expect_board_count: 2
      expect_undoable: false
      expect_loc: (70,20)
  expect_final_board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦

scenario undo_split_piece_returns_to_split_position
  desc: Undo of a move on a split piece restores it to the split position, not the pre-split position.
  op: undo_walkthrough
  board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
  steps:
    step_1:
      desc: board has two stacks at their initial positions
      expect_board_count: 2
      expect_undoable: false
    step_2:
      desc: player splits K♠-A♠-2♠-3♠ at midpoint — tie on chunk size, so the right [2♠ 3♠] nudges up to (top=16, left=138).
      action: split K♠ A♠ / 2♠ 3♠
      expect_board_count: 3
      expect_undoable: true
      expect_loc: (138,16)
    step_3:
      desc: player moves the 2♠-3♠ piece to a distant spot
      action: move_stack [2♠ 3♠] -> (400,500)
      expect_board_count: 3
      expect_undoable: true
      expect_loc: (400,500)
    step_4:
      desc: undo the move — 2♠-3♠ returns to its split position, not (20, 70)
      action: undo
      expect_board_count: 3
      expect_undoable: true
      expect_loc: (138,16)
    step_5:
      desc: undo the split — K♠-A♠-2♠-3♠ reassembled at original position
      action: undo
      expect_board_count: 2
      expect_undoable: false
      expect_loc: (70,20)
  expect_final_board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
