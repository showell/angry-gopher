module Test.AgentPlanFixtures exposing
    ( minedOneFourMovePlanJson
    , mouseUpBoardPlanJson
    , simplePeelPlanJson
    )

{-| Hand-baked engine_play plan fixtures for Elm tests.

Each constant here is the JSON shape `engine_glue.js` produces
in the production browser flow — captured once from a real
`LynRummyEngine.agentPlay(board)` call against the test board
and pasted in. Tests pipe these through
`Test.AgentPlayBridge.clickWithPlanJson` instead of running the
JS bundle, since elm-test runs in Node without Browser.element
ports.

If the engine output for any of these boards changes, regenerate
by running:

    node tools/regen_agent_plan_fixtures.js

(or, until that helper exists, by ad-hoc capture as documented
in the Phase 2 spec at `~/showell_repos/claude-steve/TS_ELM_INTEGRATION.md`).

The board geometry is part of the input, so any time a board
literal in `AgentPlayThroughTest.elm` changes loc fields, the
matching fixture here may need a refresh too.

-}


{-| Plan for the simplePeelBoard:
[TC JD QS KH] at (50, 50) + [9D] at (100, 200).

Engine returns one batch (push TROUBLE [9D] onto HELPER) =
one merge_stack primitive. The post-state is a length-5 RB run
[9D TC JD QS KH] — victory.
-}
simplePeelPlanJson : String
simplePeelPlanJson =
    """[{"line":"push TROUBLE [9D] onto HELPER [TC JD QS KH] → [9D TC JD QS KH]","wire_actions":[{"action":"merge_stack","source":{"board_cards":[{"card":{"value":9,"suit":1,"origin_deck":0},"state":0}],"loc":{"top":100,"left":200}},"target":{"board_cards":[{"card":{"value":10,"suit":0,"origin_deck":0},"state":0},{"card":{"value":11,"suit":1,"origin_deck":0},"state":0},{"card":{"value":12,"suit":2,"origin_deck":0},"state":0},{"card":{"value":13,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":50,"left":50}},"side":"left"}]}]"""


{-| Plan for the mouseUp test's push-only board:
[AD] at (100, 100) + [2C 3D 4C 5H 6S 7H] at (200, 100).

One batch with one merge_stack. Same shape as simplePeel —
the difference is that this test specifically targets the
mouseUp-during-Animating edge case in the Replay FSM.
-}
mouseUpBoardPlanJson : String
mouseUpBoardPlanJson =
    """[{"line":"push TROUBLE [AD] onto HELPER [2C 3D 4C 5H 6S 7H] → [AD 2C 3D 4C 5H 6S 7H]","wire_actions":[{"action":"merge_stack","source":{"board_cards":[{"card":{"value":1,"suit":1,"origin_deck":0},"state":0}],"loc":{"top":100,"left":100}},"target":{"board_cards":[{"card":{"value":2,"suit":0,"origin_deck":0},"state":0},{"card":{"value":3,"suit":1,"origin_deck":0},"state":0},{"card":{"value":4,"suit":0,"origin_deck":0},"state":0},{"card":{"value":5,"suit":3,"origin_deck":0},"state":0},{"card":{"value":6,"suit":2,"origin_deck":0},"state":0},{"card":{"value":7,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":200,"left":100}},"side":"left"}]}]"""


{-| Plan for the mined001Board (4S+4Cp1) walkthrough.

Four batches that walk the board from a 10-stack mid-puzzle
state to victory. Used by both the standard model test and the
puzzle-session-shaped model variant — exercises the click-walk
program-counter advancement across multiple batches.
-}
minedOneFourMovePlanJson : String
minedOneFourMovePlanJson =
    """[{"line":"steal 4D' from HELPER [2D' 3S' 4D'], absorb onto trouble [4S 4C'] → [4S 4C' 4D'] [→COMPLETE] ; spawn TROUBLE: [2D' 3S']","wire_actions":[{"action":"split","stack":{"board_cards":[{"card":{"value":2,"suit":1,"origin_deck":1},"state":0},{"card":{"value":3,"suit":2,"origin_deck":1},"state":0},{"card":{"value":4,"suit":1,"origin_deck":1},"state":0}],"loc":{"top":332,"left":52}},"card_index":2},{"action":"merge_stack","source":{"board_cards":[{"card":{"value":4,"suit":1,"origin_deck":1},"state":0}],"loc":{"top":328,"left":122}},"target":{"board_cards":[{"card":{"value":4,"suit":2,"origin_deck":0},"state":0},{"card":{"value":4,"suit":0,"origin_deck":1},"state":0}],"loc":{"top":332,"left":187}},"side":"right"}]},{"line":"steal AC from HELPER [AC AD AH], absorb onto trouble [2D' 3S'] → [AC 2D' 3S'] [→COMPLETE] ; spawn TROUBLE: [AD], [AH]","wire_actions":[{"action":"split","stack":{"board_cards":[{"card":{"value":1,"suit":0,"origin_deck":0},"state":0},{"card":{"value":1,"suit":1,"origin_deck":0},"state":0},{"card":{"value":1,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":182,"left":52}},"card_index":0},{"action":"move_stack","stack":{"board_cards":[{"card":{"value":1,"suit":1,"origin_deck":0},"state":0},{"card":{"value":1,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":182,"left":93}},"new_loc":{"top":407,"left":187}},{"action":"split","stack":{"board_cards":[{"card":{"value":1,"suit":1,"origin_deck":0},"state":0},{"card":{"value":1,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":407,"left":187}},"card_index":0},{"action":"merge_stack","source":{"board_cards":[{"card":{"value":1,"suit":0,"origin_deck":0},"state":0}],"loc":{"top":178,"left":50}},"target":{"board_cards":[{"card":{"value":2,"suit":1,"origin_deck":1},"state":0},{"card":{"value":3,"suit":2,"origin_deck":1},"state":0}],"loc":{"top":332,"left":44}},"side":"left"}]},{"line":"push TROUBLE [AD] onto HELPER [2C 3D 4C 5H 6S 7H] → [AD 2C 3D 4C 5H 6S 7H]","wire_actions":[{"action":"merge_stack","source":{"board_cards":[{"card":{"value":1,"suit":1,"origin_deck":0},"state":0}],"loc":{"top":403,"left":185}},"target":{"board_cards":[{"card":{"value":2,"suit":0,"origin_deck":0},"state":0},{"card":{"value":3,"suit":1,"origin_deck":0},"state":0},{"card":{"value":4,"suit":0,"origin_deck":0},"state":0},{"card":{"value":5,"suit":3,"origin_deck":0},"state":0},{"card":{"value":6,"suit":2,"origin_deck":0},"state":0},{"card":{"value":7,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":257,"left":52}},"side":"left"}]},{"line":"push TROUBLE [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]","wire_actions":[{"action":"move_stack","stack":{"board_cards":[{"card":{"value":2,"suit":3,"origin_deck":0},"state":0},{"card":{"value":3,"suit":3,"origin_deck":0},"state":0},{"card":{"value":4,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":26,"left":26}},"new_loc":{"top":482,"left":220}},{"action":"merge_stack","source":{"board_cards":[{"card":{"value":1,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":407,"left":228}},"target":{"board_cards":[{"card":{"value":2,"suit":3,"origin_deck":0},"state":0},{"card":{"value":3,"suit":3,"origin_deck":0},"state":0},{"card":{"value":4,"suit":3,"origin_deck":0},"state":0}],"loc":{"top":482,"left":220}},"side":"left"}]}]"""
