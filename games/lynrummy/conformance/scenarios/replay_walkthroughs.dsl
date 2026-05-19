# One scenario per mined puzzle — a full agent-play walkthrough
# end-to-end. Each scenario asserts that the Replay FSM and the
# eager applier agree on the final model AND that the puzzle ends
# in victory.

scenario walkthrough_mined_001_4♠_4♣p1
  desc: Full agent-play walkthrough for mined_001_4♠_4♣p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): A♣ A♦ A♥
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 3♠' 4♦'
    at (52,407): A♠ 2♠ 3♠
    at (52,482): K♦' K♥' K♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣' T♦
    at (187,332): 4♠ 4♣'
  actions:
    - split 2♦' 3♠' / 4♦' at (52,332)
    - merge_stack [4♦'] -> [4♠ 4♣'] /right
    - split A♣ / A♦ A♥ at (52,182)
    - move_stack [A♦ A♥] -> (187,407)
    - split A♦ / A♥ at (187,407)
    - merge_stack [A♣] -> [2♦' 3♠'] /left
    - merge_stack [A♦] -> [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] /left
    - move_stack [2♥ 3♥ 4♥] -> (220,482)
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_002_Q♦p1
  desc: Full agent-play walkthrough for mined_002_Q♦p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): A♠ 2♠ 3♠
    at (52,182): K♦' K♥' K♠
    at (52,257): J♦ Q♦ K♦
    at (52,332): T♠ T♣' T♦
    at (52,407): 4♠ 4♣' 4♦'
    at (52,482): A♣ 2♦' 3♠'
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): A♦ 2♣ 3♦ 4♣
    at (187,242): 6♠ 7♥ 8♠
    at (187,317): 5♣ 5♦ 5♥
    at (187,392): Q♦'
  actions:
    - split A♦ / 2♣ 3♦ 4♣ at (187,167)
    - move_stack [J♦ Q♦ K♦] -> (187,467)
    - merge_stack [A♦] -> [J♦ Q♦ K♦] /right
    - split J♦ / Q♦ K♦ A♦ at (187,467)
    - move_stack [Q♦'] -> (85,257)
    - merge_stack [J♦] -> [Q♦'] /left
    - split K♦' / K♥' K♠ at (52,182)
    - move_stack [K♥' K♠] -> (187,392)
    - split K♥' / K♠ at (187,392)
    - merge_stack [K♦'] -> [J♦ Q♦'] /right
    - merge_stack [K♥'] -> [A♣ 2♦' 3♠'] /left
    - merge_stack [K♠] -> [A♠ 2♠ 3♠] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_003_6♦
  desc: Full agent-play walkthrough for mined_003_6♦; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): A♣ A♦ A♥
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 2♥' 2♣
    at (52,407): J♦ Q♦ K♦
    at (52,482): 8♦' 9♣ T♦
    at (187,92): 7♥' 8♠ 9♥'
    at (187,167): Q♠' Q♣' Q♥
    at (187,332): A♠ 2♠ 3♠
    at (187,407): K♦' K♣' K♠
    at (187,482): 6♦
  actions:
    - split 7♠ 7♦ / 7♣ at (52,107)
    - move_stack [7♠ 7♦] -> (247,242)
    - split 7♠ / 7♦ at (247,242)
    - merge_stack [7♣] -> [6♦] /right
    - move_stack [8♦' 9♣ T♦] -> (358,482)
    - merge_stack [6♦ 7♣] -> [8♦' 9♣ T♦] /left
    - merge_stack [7♦] -> [7♠] /right
    - split 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,257)
    - merge_stack [7♥] -> [7♠ 7♦] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_004_5♣_6♦p1
  desc: Full agent-play walkthrough for mined_004_5♣_6♦p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♠' 5♦' 6♣
    at (187,182): 5♣ 6♦'
  actions:
    - split 7♠ 7♦ / 7♣ at (52,257)
    - move_stack [7♠ 7♦] -> (187,257)
    - split 7♠ / 7♦ at (187,257)
    - merge_stack [7♣] -> [5♣ 6♦'] /right
    - merge_stack [7♦] -> [7♠] /right
    - split 2♣ 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,407)
    - merge_stack [7♥] -> [7♠ 7♦] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_005_2♥p1
  desc: Full agent-play walkthrough for mined_005_2♥p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): A♣ A♦ A♥
    at (52,332): 4♠' 5♦' 6♣
    at (52,407): 5♣ 6♦' 7♣
    at (52,482): 2♣ 3♦ 4♣ 5♥ 6♠
    at (187,182): 7♠ 7♦ 7♥
    at (187,257): 2♥'
  actions:
    - split K♠ A♠ 2♠ / 3♠ at (26,26)
    - merge_stack [3♠] -> [2♥'] /right
    - split A♣ / A♦ A♥ at (52,257)
    - move_stack [A♦ A♥] -> (187,332)
    - split A♦ / A♥ at (187,332)
    - merge_stack [A♣] -> [2♥' 3♠] /left
    - merge_stack [A♦] -> [T♦ J♦ Q♦ K♦] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_006_6♣p1
  desc: Full agent-play walkthrough for mined_006_6♣p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 4♠' 5♦' 6♣
    at (52,107): 5♣ 6♦' 7♣
    at (52,182): 7♠ 7♦ 7♥
    at (52,257): K♠ A♠ 2♠
    at (52,332): 3♦ 4♣ 5♥ 6♠
    at (52,407): K♠' A♦ 2♣
    at (52,482): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥
    at (187,167): Q♣ K♦ A♣
    at (187,242): A♣' 2♥' 3♠ 4♥
    at (187,407): 6♣'
  actions:
    - split 3♦ 4♣ 5♥ / 6♠ at (52,332)
    - merge_stack [6♠] -> [6♣'] /right
    - split 5♣ / 6♦' 7♣ at (52,107)
    - split 6♦' / 7♣ at (87,107)
    - merge_stack [6♦'] -> [6♣' 6♠] /right
    - merge_stack [5♣] -> [A♣' 2♥' 3♠ 4♥] /right
    - move_stack [7♠ 7♦ 7♥] -> (187,482)
    - merge_stack [7♣] -> [7♠ 7♦ 7♥] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_007_5♣p1_6♣
  desc: Full agent-play walkthrough for mined_007_5♣p1_6♣; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♥' T♣' J♥
    at (187,182): 5♣' 6♣
  actions:
    - split 7♠ 7♦ / 7♣ at (52,257)
    - move_stack [7♠ 7♦] -> (187,257)
    - split 7♠ / 7♦ at (187,257)
    - merge_stack [7♣] -> [5♣' 6♣] /right
    - merge_stack [7♦] -> [7♠] /right
    - split 2♣ 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,407)
    - merge_stack [7♥] -> [7♠ 7♦] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_008_Q♥p1
  desc: Full agent-play walkthrough for mined_008_Q♥p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 9♥' T♣' J♥
    at (52,332): 5♣' 6♣ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,482): 7♠ 7♦ 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): J♠' Q♠' K♠
    at (187,242): Q♥'
  actions:
    - split J♠' / Q♠' K♠ at (187,167)
    - move_stack [Q♥'] -> (220,242)
    - merge_stack [J♠'] -> [Q♥'] /left
    - split T♦ / J♦ Q♦ K♦ at (26,26)
    - move_stack [J♠' Q♥'] -> (220,242)
    - merge_stack [T♦] -> [J♠' Q♥'] /left
    - move_stack [A♠ 2♠ 3♠] -> (253,92)
    - merge_stack [Q♠' K♠] -> [A♠ 2♠ 3♠] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_009_J♣
  desc: Full agent-play walkthrough for mined_009_J♣; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): A♣ A♦ A♥
    at (52,107): 9♥' T♣' J♥
    at (52,182): 5♣' 6♣ 7♣
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,332): 7♠ 7♦ 7♥
    at (52,407): J♦ Q♦ K♦
    at (52,482): Q♠' K♠ A♠ 2♠ 3♠
    at (187,92): 9♠ T♦ J♠' Q♥'
    at (187,167): 2♥ 3♥ 4♥ 5♥'
    at (187,332): J♣
  actions:
    - split 9♠ T♦ J♠' / Q♥' at (187,92)
    - merge_stack [Q♥'] -> [J♣] /right
    - split Q♠' / K♠ A♠ 2♠ 3♠ at (52,482)
    - split K♠ / A♠ 2♠ 3♠ at (87,482)
    - merge_stack [K♠] -> [J♣ Q♥'] /right
    - move_stack [9♥' T♣' J♥] -> (187,407)
    - merge_stack [Q♠'] -> [9♥' T♣' J♥] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_010_3♥p1
  desc: Full agent-play walkthrough for mined_010_3♥p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 9♥' 9♣ 9♦
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,482): 5♦' 6♣' 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): K♣' K♦' K♠
    at (187,242): T♣' J♦' Q♠
    at (187,317): 3♥'
  actions:
    - split 2♣ / 3♦ 4♣ 5♥ 6♠ at (52,407)
    - move_stack [3♥'] -> (220,317)
    - merge_stack [2♣] -> [3♥'] /left
    - split A♣ / A♦ A♥ at (52,257)
    - move_stack [A♦ A♥] -> (187,482)
    - split A♦ / A♥ at (187,482)
    - move_stack [2♣ 3♥'] -> (220,317)
    - merge_stack [A♦] -> [2♣ 3♥'] /left
    - split T♦ J♦ Q♦ / K♦ at (26,26)
    - merge_stack [K♦] -> [A♣] /left
    - merge_stack [K♦ A♣] -> [T♣' J♦' Q♠] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_011_J♣
  desc: Full agent-play walkthrough for mined_011_J♣; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 9♥' 9♣ 9♦
    at (52,182): A♠ 2♠ 3♠
    at (52,257): K♣' K♦' K♠
    at (52,332): A♦ 2♣ 3♥'
    at (52,407): T♦ J♦ Q♦
    at (52,482): T♣' J♦' Q♠ K♦ A♣
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): 4♣ 5♥ 6♠
    at (187,242): 6♣' 7♥ 8♠
    at (187,317): 3♦ 4♦ 5♦'
    at (187,392): J♣
  actions:
    - split T♣' / J♦' Q♠ K♦ A♣ at (52,482)
    - move_stack [J♣] -> (220,392)
    - merge_stack [T♣'] -> [J♣] /left
    - split 9♥' / 9♣ 9♦ at (52,107)
    - move_stack [9♣ 9♦] -> (262,467)
    - split 9♣ / 9♦ at (262,467)
    - move_stack [T♣' J♣] -> (220,392)
    - merge_stack [9♣] -> [T♣' J♣] /left
    - merge_stack [9♥'] -> [6♣' 7♥ 8♠] /right
    - merge_stack [9♦] -> [T♦ J♦ Q♦] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_012_Q♣_K♣
  desc: Full agent-play walkthrough for mined_012_Q♣_K♣; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♦' 5♠ 6♦'
    at (187,182): Q♣ K♣
  actions:
    - split A♣ / A♦ A♥ at (52,332)
    - move_stack [A♦ A♥] -> (112,332)
    - split A♦ / A♥ at (112,332)
    - merge_stack [A♣] -> [Q♣ K♣] /right
    - merge_stack [A♦] -> [T♦ J♦ Q♦ K♦] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_013_A♥p1
  desc: Full agent-play walkthrough for mined_013_A♥p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): T♦ J♦ Q♦ K♦ A♦
    at (52,257): A♥ 2♥ 3♥
    at (52,332): 4♠' 4♦ 4♥
    at (52,407): 2♦ 3♣' 4♦' 5♠ 6♦'
    at (52,482): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,92): K♣ A♣ 2♣
    at (187,257): T♣' J♥ Q♣
    at (187,332): A♥'
  actions:
    - split K♠ / A♠ 2♠ 3♠ at (26,26)
    - move_stack [A♥'] -> (220,332)
    - merge_stack [K♠] -> [A♥'] /left
    - split A♠ / 2♠ 3♠ at (61,26)
    - split 2♠ / 3♠ at (96,26)
    - merge_stack [2♠] -> [K♠ A♥'] /right
    - merge_stack [A♠] -> [2♦ 3♣' 4♦' 5♠ 6♦'] /left
    - move_stack [A♠ 2♦ 3♣' 4♦' 5♠ 6♦'] -> (52,407)
    - split A♠ 2♦ / 3♣' 4♦' 5♠ 6♦' at (52,407)
    - move_stack [A♠ 2♦] -> (247,167)
    - merge_stack [3♠] -> [A♠ 2♦] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_014_5♣
  desc: Full agent-play walkthrough for mined_014_5♣; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): T♦ J♦ Q♦ K♦ A♦
    at (52,182): A♥ 2♥ 3♥
    at (52,257): 4♠' 4♦ 4♥
    at (52,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): K♣ A♣ 2♣
    at (52,482): T♣' J♥ Q♣
    at (187,182): K♠ A♥' 2♠
    at (187,257): 3♣' 4♦' 5♠ 6♦'
    at (187,407): A♠ 2♦ 3♠
    at (187,482): 5♣
  actions:
    - split 3♣' 4♦' 5♠ / 6♦' at (187,257)
    - merge_stack [6♦'] -> [5♣] /right
    - split 7♠ 7♦ / 7♣ at (26,26)
    - move_stack [7♠ 7♦] -> (247,92)
    - split 7♠ / 7♦ at (247,92)
    - merge_stack [7♣] -> [5♣ 6♦'] /right
    - merge_stack [7♦] -> [7♠] /right
    - split 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,332)
    - merge_stack [7♥] -> [7♠ 7♦] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_015_3♣p1
  desc: Full agent-play walkthrough for mined_015_3♣p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): 9♠ T♠' J♠
    at (52,482): J♦ Q♦ K♦
    at (187,92): 8♦ 9♦ T♦
    at (187,167): 2♥' 2♣' 2♦
    at (187,242): 3♣'
  actions:
    - split 2♣ / 3♦ 4♣ 5♥ 6♠ 7♥ at (52,332)
    - move_stack [3♣'] -> (220,242)
    - merge_stack [2♣] -> [3♣'] /left
    - split A♣ / A♦ A♥ at (52,257)
    - move_stack [A♦ A♥] -> (187,407)
    - split A♦ / A♥ at (187,407)
    - merge_stack [A♣] -> [2♣ 3♣'] /left
    - merge_stack [A♦] -> [J♦ Q♦ K♦] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_016_T♣p1
  desc: Full agent-play walkthrough for mined_016_T♣p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 8♦ 9♦ T♦
    at (52,182): 2♥' 2♣' 2♦
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): A♣ 2♣ 3♣'
    at (52,407): A♥ 2♥ 3♥ 4♥
    at (52,482): A♠ 2♠ 3♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): Q♥ K♠ A♦
    at (187,332): 9♠ T♠' J♠ Q♠
    at (187,482): T♣'
  actions:
    - split J♦ / Q♦ K♦ at (187,92)
    - merge_stack [J♦] -> [T♣'] /right
    - split 9♠ T♠' J♠ / Q♠ at (187,332)
    - merge_stack [Q♠] -> [T♣' J♦] /right
    - split Q♥ K♠ / A♦ at (187,167)
    - merge_stack [A♦] -> [Q♦ K♦] /right
    - split A♥ / 2♥ 3♥ 4♥ at (52,407)
    - merge_stack [A♥] -> [Q♥ K♠] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_017_5♦p1_6♦p1
  desc: Full agent-play walkthrough for mined_017_5♦p1_6♦p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 5♦' 6♦'
  actions:
    - split 7♠ / 7♦ 7♣ at (52,257)
    - move_stack [7♦ 7♣] -> (112,257)
    - split 7♦ / 7♣ at (112,257)
    - merge_stack [7♦] -> [5♦' 6♦'] /right
    - merge_stack [7♣] -> [7♠] /right
    - split 2♣ 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,407)
    - merge_stack [7♥] -> [7♠ 7♣] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_018_2♠p1_3♥p1
  desc: Full agent-play walkthrough for mined_018_2♠p1_3♥p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): 7♠' 8♦' 9♣'
    at (52,482): 3♣' 4♥' 5♠'
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣ T♦
    at (187,242): 2♠' 3♥'
  actions:
    - split A♣ / A♦ A♥ at (52,257)
    - move_stack [A♦ A♥] -> (187,407)
    - split A♦ / A♥ at (187,407)
    - merge_stack [A♦] -> [2♠' 3♥'] /left
    - split 2♣ / 3♦ 4♣ 5♥ 6♠ 7♥ at (52,332)
    - move_stack [A♣] -> (187,482)
    - merge_stack [2♣] -> [A♣] /right
    - split 3♣' / 4♥' 5♠' at (52,482)
    - merge_stack [3♣'] -> [A♣ 2♣] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
    - split K♠ A♠ 2♠ / 3♠ at (26,26)
    - merge_stack [3♠] -> [4♥' 5♠'] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_019_2♦
  desc: Full agent-play walkthrough for mined_019_2♦; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): J♦ Q♦ K♦
    at (52,182): T♣' T♥ T♦
    at (52,257): 5♣' 6♦ 7♣'
    at (52,332): 6♠ 7♥ 8♣'
    at (52,407): A♣ 2♦' 3♠'
    at (52,482): A♠ 2♠ 3♠
    at (187,92): K♠ A♦ 2♣'
    at (187,167): 2♥ 3♥ 4♥ 5♥
    at (187,242): A♥ 2♣ 3♦ 4♣
    at (187,317): 2♦
  actions:
    - split K♠ / A♦ 2♣' at (187,92)
    - split A♦ / 2♣' at (222,92)
    - move_stack [2♦] -> (220,317)
    - merge_stack [A♦] -> [2♦] /left
    - move_stack [J♦ Q♦ K♦] -> (187,467)
    - merge_stack [A♦ 2♦] -> [J♦ Q♦ K♦] /right
    - move_stack [A♥ 2♣ 3♦ 4♣] -> (220,242)
    - merge_stack [K♠] -> [A♥ 2♣ 3♦ 4♣] /left
    - split K♠ A♥ / 2♣ 3♦ 4♣ at (187,242)
    - move_stack [K♠ A♥] -> (52,107)
    - merge_stack [2♣'] -> [K♠ A♥] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_020_2♦p1_3♣p1
  desc: Full agent-play walkthrough for mined_020_2♦p1_3♣p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): J♦ Q♦ K♦
    at (52,482): T♣ T♥ T♦
    at (187,92): 9♦ 9♣' 9♠'
    at (187,167): 2♦' 3♣'
  actions:
    - split A♣ / A♦ A♥ at (52,257)
    - move_stack [A♦ A♥] -> (112,257)
    - split A♦ / A♥ at (112,257)
    - move_stack [2♦' 3♣'] -> (220,167)
    - merge_stack [A♣] -> [2♦' 3♣'] /left
    - merge_stack [A♦] -> [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] /left
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_021_8♦p1
  desc: Full agent-play walkthrough for mined_021_8♦p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): J♥' J♦' J♣
    at (187,182): 4♥' 5♣' 6♦'
    at (187,257): 6♠' 7♥' 8♣' 9♥
    at (187,332): 8♦'
  actions:
    - split 7♠ 7♦ / 7♣ at (52,257)
    - move_stack [7♠ 7♦] -> (187,482)
    - split 7♠ / 7♦ at (187,482)
    - move_stack [8♦'] -> (220,332)
    - merge_stack [7♣] -> [8♦'] /left
    - split K♠ A♠ 2♠ / 3♠ at (26,26)
    - move_stack [4♥' 5♣' 6♦'] -> (220,182)
    - merge_stack [3♠] -> [4♥' 5♣' 6♦'] /left
    - split 3♠ 4♥' 5♣' / 6♦' at (187,182)
    - merge_stack [6♦'] -> [7♣ 8♦'] /left
    - merge_stack [7♦] -> [7♠] /right
    - split 2♣ 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,407)
    - merge_stack [7♥] -> [7♠ 7♦] /right
  expect:
    final_board_victory: true

scenario walkthrough_mined_022_A♥p1_A♦p1
  desc: Full agent-play walkthrough for mined_022_A♥p1_A♦p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♣ T♥ J♠
    at (187,182): A♥' A♦'
  actions:
    - split A♣ / A♦ A♥ at (52,332)
    - move_stack [A♦ A♥] -> (112,332)
    - split A♦ / A♥ at (112,332)
    - merge_stack [A♣] -> [A♥' A♦'] /right
    - merge_stack [A♦] -> [T♦ J♦ Q♦ K♦] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_023_3♣
  desc: Full agent-play walkthrough for mined_023_3♣; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 9♣ T♥ J♠
    at (52,182): A♥' A♦' A♣
    at (52,257): T♦ J♦ Q♦ K♦ A♦
    at (52,332): A♥ 2♥ 3♥ 4♥
    at (52,407): 7♠ 7♦ 7♣ 7♥'
    at (52,482): 4♣ 5♥ 6♠ 7♥
    at (187,92): 2♣ 3♦ 4♠'
    at (187,167): 3♣
  actions:
    - split 4♣ / 5♥ 6♠ 7♥ at (52,482)
    - merge_stack [4♣] -> [3♣] /right
    - split 2♣ / 3♦ 4♠' at (187,92)
    - move_stack [3♣ 4♣] -> (220,167)
    - merge_stack [2♣] -> [3♣ 4♣] /left
    - merge_stack [3♦ 4♠'] -> [5♥ 6♠ 7♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_024_2♦
  desc: Full agent-play walkthrough for mined_024_2♦; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 8♥ 9♠ T♥'
    at (187,182): 9♣ T♥ J♣
    at (187,257): 2♦
  actions:
    - split K♠ A♠ 2♠ / 3♠ at (26,26)
    - merge_stack [3♠] -> [2♦] /right
    - split A♣ / A♦ A♥ at (52,332)
    - move_stack [A♦ A♥] -> (112,332)
    - split A♦ / A♥ at (112,332)
    - move_stack [2♦ 3♠] -> (220,257)
    - merge_stack [A♣] -> [2♦ 3♠] /left
    - merge_stack [A♦] -> [T♦ J♦ Q♦ K♦] /right
    - merge_stack [A♥] -> [2♥ 3♥ 4♥] /left
  expect:
    final_board_victory: true

scenario walkthrough_mined_025_T♠p1
  desc: Full agent-play walkthrough for mined_025_T♠p1; bootstrapFromBundle reconstructs to a victory board.
  op: resume_walkthrough
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,182): 8♥ 9♠ T♥'
    at (52,257): 9♣ T♥ J♣
    at (52,332): K♠ A♠ 2♠
    at (52,407): A♣ 2♦ 3♠
    at (52,482): T♦ J♦ Q♦ K♦ A♦
    at (187,182): A♥ 2♥ 3♥
    at (187,257): 4♦ 4♠' 4♥
    at (187,332): T♠'
  actions:
    - split T♦ / J♦ Q♦ K♦ A♦ at (52,482)
    - merge_stack [T♦] -> [T♠'] /right
    - split 8♥ 9♠ / T♥' at (52,182)
    - merge_stack [T♥'] -> [T♠' T♦] /right
    - split 7♠ 7♦ / 7♣ at (26,26)
    - move_stack [7♠ 7♦] -> (187,407)
    - split 7♠ / 7♦ at (187,407)
    - merge_stack [7♣] -> [8♥ 9♠] /left
    - merge_stack [7♦] -> [7♠] /right
    - split 2♣ 3♦ 4♣ 5♥ 6♠ / 7♥ at (52,107)
    - merge_stack [7♥] -> [7♠ 7♦] /right
  expect:
    final_board_victory: true
