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
      - split [T♦ J♦ Q♦ K♦] at (100,100) @0
      - merge_stack [T♦] at (98,96) -> [J♦' Q♦'] at (52,272) /left :: path (98,96@0)(98,96@25)(97,98@50)(96,101@75)(93,108@100)(89,117@125)(84,128@150)(78,142@175)(71,158@200)(63,174@225)(56,192@250)(48,208@275)(41,224@300)(35,238@325)(30,249@351)(26,258@376)(23,265@401)(22,268@426)(21,270@451)(21,270@476)
scenario single_card_two_verb_plan
  desc: 4♠ from hand; the augmented board has two troubles ([J♦' Q♦'] partial + the new 4♠ singleton). BFS finds a 2-move plan — peel T♦ onto [J♦' Q♦'] completes it, then push 4♠ onto [K♠ A♠ 2♠ 3♠] as a merge_hand, consuming the hand card directly.
  board:
    at (100,100): K♠ A♠ 2♠ 3♠
    at (100,200): T♦ J♦ Q♦ K♦
    at (100,300): J♦' Q♦'
  hand: 4♠
  expect:
    primitives:
      - split [T♦ J♦ Q♦ K♦] at (100,200) @0
      - merge_stack [T♦] at (98,196) -> [J♦' Q♦'] at (100,300) /left :: path (98,196@0)(98,196@14)(98,197@28)(97,199@42)(96,203@56)(95,208@70)(93,215@84)(90,223@98)(88,232@112)(85,242@126)(82,252@140)(79,262@153)(77,271@167)(74,279@181)(72,286@195)(71,291@209)(70,295@223)(69,297@237)(69,298@251)(69,298@265)
      - merge_hand 4♠ -> [K♠ A♠ 2♠ 3♠] at (100,100) /right