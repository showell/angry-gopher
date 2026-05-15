# elm_find_play_corpus — Elm puzzles wrapper integration scenarios.
#
# Each scenario gives a board + hand and pins the primitive sequence
# returned by `elm_api/elm_find_play.ts:elmFindPlay`. The runner
# treats the DSL as the assertion surface — both inputs and the
# expected output stay as DSL strings on either side of the wrapper.
#
# Compared to physical_plan_corpus, scenarios here drop the explicit
# `plan:` block: the wrapper IS the planner. The output covers the
# full findPlayPrimitives pipeline (logical search → physical
# lowering).

scenario seed_extend_partial_run
  desc: 5H from hand free-pulls onto partial [3H 4H]; one merge_hand primitive.
  board:
    at (100, 100): 3H 4H
    at (200, 100): QC QD QH
  hand: 5H
  expect:
    primitives:
      - merge_hand 5H -> [3H 4H] /right

scenario triple_in_hand_clean_board
  desc: hand contains a complete set [5S 5D 5C]; board is all helpers (clean). The triple-in-hand short-circuit fires — no BFS plan, just lay the three cards down at a fresh open loc as a seed chain.
  board:
    at (100, 100): KS AS 2S 3S
    at (200, 100): TD JD QD KD
  hand: 5S 5D 5C
  expect:
    primitives:
      - place_hand 5S -> (272,52)
      - merge_hand 5D -> [5S] /right
      - merge_hand 5C -> [5S 5D] /right

scenario pair_from_hand_then_peel
  desc: pair [JD' QD'] placed at fresh loc (multi-placement seed), then BFS plan peels TD off the helper run [TD JD QD KD] and merges it left onto the hand-laid pair to form the complete run [TD JD' QD'].
  board:
    at (100, 100): TD JD QD KD
    at (200, 100): KS AS 2S 3S
  hand: JD' QD'
  expect:
    primitives:
      - place_hand JD' -> (272,52)
      - merge_hand QD' -> [JD'] /right
      - split [TD JD QD KD]@0
      - merge_stack [TD] -> [JD' QD'] /left

scenario single_card_two_verb_plan
  desc: 4S from hand; the augmented board has two troubles ([JD' QD'] partial + the new 4S singleton). BFS finds a 2-move plan — peel TD onto [JD' QD'] completes it, then push 4S onto [KS AS 2S 3S] as a merge_hand, consuming the hand card directly.
  board:
    at (100, 100): KS AS 2S 3S
    at (200, 100): TD JD QD KD
    at (300, 100): JD' QD'
  hand: 4S
  expect:
    primitives:
      - split [TD JD QD KD]@0
      - merge_stack [TD] -> [JD' QD'] /left
      - merge_hand 4S -> [KS AS 2S 3S] /right
