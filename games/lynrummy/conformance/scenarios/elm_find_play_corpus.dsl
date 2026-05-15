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
