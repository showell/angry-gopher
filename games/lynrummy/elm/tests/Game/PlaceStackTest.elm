module Game.PlaceStackTest exposing (suite)

{-| Pure-Elm tests for `Game.PlaceStack` math that doesn't
need cross-language parity. Anything that asserts Python-Elm
agreement on `findOpenLoc` lives in
`games/lynrummy/conformance/scenarios/place_stack.dsl` and is
generated into `Game.DslConformanceTest`.
-}

import Expect
import Game.Physics.PlaceStack as PS
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Game.PlaceStack"
        [ stackWidthTests ]


stackWidthTests : Test
stackWidthTests =
    describe "stackWidth"
        [ test "0 cards -> 0" <| \_ -> Expect.equal 0 (PS.stackWidth 0)
        , test "1 card -> CARD_WIDTH = 27" <| \_ -> Expect.equal 27 (PS.stackWidth 1)
        , test "2 cards -> 27 + 33" <| \_ -> Expect.equal (27 + 33) (PS.stackWidth 2)
        , test "3 cards -> 27 + 33*2" <| \_ -> Expect.equal (27 + 33 * 2) (PS.stackWidth 3)
        , test "12 cards -> 27 + 33*11" <| \_ -> Expect.equal (27 + 33 * 11) (PS.stackWidth 12)
        ]
