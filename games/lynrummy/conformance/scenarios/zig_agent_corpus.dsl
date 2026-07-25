# zig_agent_corpus — Player Two end-to-end conformance: board + hand
# DSL through the REAL solver.wasm (`agentStep`) and the TS lowering
# (`zigPlanPrimitives`), pinning the primitive sequence Elm would
# animate. This is the cross-language drift alarm: a zig recipe-format
# change, a policy change, or a lowering change all fail here first.
#
# Empty `primitives:` block = the agent is stuck (wasm returned 0) —
# the end-of-turn signal.
#
# The runner also asserts the applied result: after a play, EVERY
# stack on the simulated board must be a complete meld (a zig play is
# a full cover by construction).

scenario extend_partial_run
  desc: 5♥ from hand completes the board's partial [3♥ 4♥]; the strongest single is also the simplest — one hand-direct merge.
  board:
    at (100,100): 3♥ 4♥
    at (100,200): Q♣ Q♦ Q♥
  hand: 5♥
  expect:
    primitives:
      - merge_hand 5♥ -> [3♥ 4♥] at (100,100) /right
scenario triple_in_hand_clean_board
  desc: no single or pair from [5♠ 5♦ 5♣] can cover, the triple can — laid down as anchor + two joiners at a fresh loc sized for the set.
  board:
    at (100,100): K♠ A♠ 2♠ 3♠
    at (100,200): T♦ J♦ Q♦ K♦
  hand: 5♠ 5♦ 5♣
  expect:
    primitives:
      - place_hand 5♦ -> (52,272)
      - merge_hand 5♠ -> [5♦] at (52,272) /right
      - merge_hand 5♣ -> [5♦ 5♠] at (52,272) /right
scenario pair_needs_board_surgery
  desc: J♦' Q♦' can only land by restructuring the diamond run — no single plays (five diamonds have no cover), the pair does. T♦ peels off as a bare anchor and the hand cards build the new run on it.
  board:
    at (100,100): T♦ J♦ Q♦ K♦
    at (100,200): K♠ A♠ 2♠ 3♠
  hand: J♦' Q♦'
  expect:
    primitives:
      - isolate ( T♦ ) J♦ Q♦ K♦ at (100,100)
      - move_stack [T♦] at (100,100) -> (52,272) :: path (100,100@0)(100,100@23)(100,102@47)(99,105@70)(97,111@94)(94,120@117)(91,132@141)(87,145@164)(83,161@188)(78,178@211)(74,194@235)(69,211@258)(65,227@282)(61,240@305)(58,252@329)(55,261@352)(53,267@376)(52,270@399)(52,272@423)(52,272@446)
      - merge_hand J♦' -> [T♦] at (52,272) /right
      - merge_hand Q♦' -> [T♦ J♦'] at (52,272) /right
scenario steal_from_mid_set
  desc: 9♦ from hand needs 6♦7♦8♦9♦ — the 8♦ comes out of the middle of the four-set (isolate), the remnant pair rejoins (zig closes the gap), then the run assembles.
  board:
    at (100,100): 8♥ 8♠ 8♦ 8♣
    at (100,300): 6♦ 7♦
  hand: 9♦
  expect:
    primitives:
      - isolate 8♥ 8♠ ( 8♦ ) 8♣ at (100,100)
      - move_stack [8♥ 8♠] at (98,100) -> (52,182) :: path (98,100@0)(98,100@12)(98,101@25)(97,103@37)(95,105@49)(93,110@62)(90,115@74)(86,122@87)(82,129@99)(77,137@111)(73,145@124)(68,153@136)(64,160@148)(60,167@161)(57,172@173)(55,177@186)(53,179@198)(52,181@210)(52,182@223)(52,182@235)
      - merge_stack [8♣] at (201,100) -> [8♥ 8♠] at (52,182) /right :: path (201,100@0)(201,100@15)(200,101@30)(199,102@45)(196,105@60)(191,109@75)(186,115@90)(180,121@105)(172,128@120)(164,136@135)(157,144@150)(149,152@165)(141,159@180)(135,165@195)(130,171@210)(125,175@225)(122,178@240)(121,179@255)(120,180@270)(120,180@285)
      - merge_stack [8♦] at (166,100) -> [6♦ 7♦] at (100,300) /right :: path (166,100@0)(166,100@26)(166,102@52)(166,106@78)(166,113@104)(166,123@130)(166,137@156)(167,152@182)(167,170@208)(167,189@234)(167,209@261)(167,228@287)(167,246@313)(168,261@339)(168,275@365)(168,285@391)(168,292@417)(168,296@443)(168,298@469)(168,298@495)
      - merge_hand 9♦ -> [6♦ 7♦ 8♦] at (100,300) /right
scenario stuck_hand_yields_turn
  desc: 9♣ on a board with no 8♣/T♣/other 9s in reach — every probe refuted, the agent draws.
  board:
    at (100,100): K♠ A♠ 2♠ 3♠
    at (100,200): 7♠ 7♦ 7♣
  hand: 9♣
  expect:
    primitives:
