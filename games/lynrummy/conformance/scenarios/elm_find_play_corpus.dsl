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
  desc: 5♥ from hand free-pulls onto partial [3♥ 4♥]; one merge_hand primitive.
  board:
    at (100,100): 3♥ 4♥
    at (100,200): Q♣ Q♦ Q♥
  hand: 5♥
  expect:
    primitives:
      - merge_hand 5♥ -> [3♥ 4♥] at (100,100) /right
scenario triple_in_hand_clean_board
  desc: hand contains a complete set [5♠ 5♦ 5♣]; board is all helpers (clean). The triple-in-hand short-circuit fires — no BFS plan, just lay the three cards down at a fresh open loc as a seed chain.
  board:
    at (100,100): K♠ A♠ 2♠ 3♠
    at (100,200): T♦ J♦ Q♦ K♦
  hand: 5♠ 5♦ 5♣
  expect:
    primitives:
      - place_hand 5♠ -> (52,272)
      - merge_hand 5♦ -> [5♠] at (52,272) /right
      - merge_hand 5♣ -> [5♠ 5♦] at (52,272) /right
scenario pair_from_hand_then_peel
  desc: pair [J♦' Q♦'] placed at fresh loc (multi-placement seed), then BFS plan peels T♦ off the helper run [T♦ J♦ Q♦ K♦] and merges it left onto the hand-laid pair to form the complete run [T♦ J♦' Q♦'].
  board:
    at (100,100): T♦ J♦ Q♦ K♦
    at (100,200): K♠ A♠ 2♠ 3♠
  hand: J♦' Q♦'
  expect:
    primitives:
      - place_hand J♦' -> (52,272)
      - merge_hand Q♦' -> [J♦'] at (52,272) /right
      - isolate ( T♦ ) J♦ Q♦ K♦
      - merge_stack [T♦] at (100,100) -> [J♦' Q♦'] at (52,272) /left :: path (100,100@0)(100,100@25)(99,102@49)(98,105@74)(95,111@99)(91,120@123)(85,131@148)(79,145@173)(72,160@197)(64,177@222)(57,193@247)(49,210@271)(42,225@296)(36,239@321)(30,250@345)(26,259@370)(23,265@395)(22,268@419)(21,270@444)(21,270@469)
scenario single_card_two_verb_plan
  desc: 4♠ from hand; the augmented board has two troubles ([J♦' Q♦'] partial + the new 4♠ singleton). BFS finds a 2-move plan — peel T♦ onto [J♦' Q♦'] completes it, then push 4♠ onto [K♠ A♠ 2♠ 3♠] as a merge_hand, consuming the hand card directly.
  board:
    at (100,100): K♠ A♠ 2♠ 3♠
    at (100,200): T♦ J♦ Q♦ K♦
    at (100,300): J♦' Q♦'
  hand: 4♠
  expect:
    primitives:
      - isolate ( T♦ ) J♦ Q♦ K♦
      - merge_stack [T♦] at (100,200) -> [J♦' Q♦'] at (100,300) /left :: path (100,200@0)(100,200@14)(100,201@27)(99,203@41)(98,206@54)(96,212@68)(94,218@81)(92,226@95)(89,235@108)(86,244@122)(83,254@135)(80,263@149)(77,272@162)(75,280@176)(73,286@189)(71,292@203)(70,295@216)(69,297@230)(69,298@243)(69,298@257)
      - merge_hand 4♠ -> [K♠ A♠ 2♠ 3♠] at (100,100) /right