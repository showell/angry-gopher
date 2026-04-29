module Game.WingOracleTest exposing (suite)

{-| Tests for `Game.WingOracle`. Two targets:

  - `wingsForStack` / `wingsForHandCard` — does the oracle
    offer the right merge targets + sides for a given source?
  - `wingBoardRect` — does the wing's computed board-frame
    rect match the positioning math that `Main.View.viewWingAt`
    uses at render time?

`WingId` identifies its target by CardStack value, so tests
construct WingIds with the full target stack and assert
equality against that stack.

-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.Rules.Card exposing (OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardLocation, CardStack)
import Game.Physics.WingOracle as WingOracle
import Test exposing (Test, describe, test)



-- HELPERS


at : Int -> Int -> BoardLocation
at left top =
    { left = left, top = top }


stackAt : String -> BoardLocation -> CardStack
stackAt shorthand loc =
    case CardStack.fromShorthand shorthand DeckOne loc of
        Just s ->
            s

        Nothing ->
            Debug.todo ("bad shorthand in test: " ++ shorthand)



-- WINGS FOR STACK


suiteWingsForStack : Test
suiteWingsForStack =
    describe "wingsForStack"
        [ test "234 + 567 (rb-run halves) offers a right wing on 234 and a left wing on 567" <|
            \_ ->
                let
                    -- Steve's real session reproduction.
                    -- Pre-split: 2C-3D-4C-5H-6S-7H (6-card rb run).
                    -- After split at card_index=3: 234 and 567.
                    stack234 =
                        stackAt "2C,3D,4C" (at 100 200)

                    stack567 =
                        stackAt "5H,6S,7H" (at 300 200)

                    board =
                        [ stack234, stack567 ]
                in
                WingOracle.wingsForStack stack567 board
                    |> Expect.equal [ { target = stack234, side = Right } ]
        , test "234 dragged toward 567 offers a LEFT wing on 567 (the other direction)" <|
            \_ ->
                let
                    stack234 =
                        stackAt "2C,3D,4C" (at 100 200)

                    stack567 =
                        stackAt "5H,6S,7H" (at 300 200)

                    board =
                        [ stack234, stack567 ]
                in
                WingOracle.wingsForStack stack234 board
                    |> Expect.equal [ { target = stack567, side = Left } ]
        , test "no wings when a merge wouldn't form a valid group" <|
            \_ ->
                let
                    aces =
                        stackAt "AC,AD,AH" (at 100 200)

                    sevens =
                        stackAt "7C,7D,7H" (at 300 200)
                in
                WingOracle.wingsForStack aces [ aces, sevens ]
                    |> Expect.equal []
        , test "self is excluded" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)
                in
                WingOracle.wingsForStack stack [ stack ]
                    |> Expect.equal []
        ]



-- WING RECT


suiteWingBoardRect : Test
suiteWingBoardRect =
    describe "wingBoardRect"
        [ test "right wing sits flush against the target's right edge" <|
            \_ ->
                let
                    target =
                        stackAt "2C,3D,4C" (at 100 200)

                    wing =
                        { target = target, side = Right }
                in
                WingOracle.wingBoardRect wing
                    |> Expect.equal
                        { left = 100 + CardStack.stackDisplayWidth target
                        , top = 200
                        , width = CardStack.stackPitch
                        , height = 40
                        }
        , test "left wing sits one pitch to the left of the target" <|
            \_ ->
                let
                    target =
                        stackAt "5H,6S,7H" (at 300 200)

                    wing =
                        { target = target, side = Left }
                in
                WingOracle.wingBoardRect wing
                    |> Expect.equal
                        { left = 300 - CardStack.stackPitch
                        , top = 200
                        , width = CardStack.stackPitch
                        , height = 40
                        }
        , test "right wing scales with target width (3-card stack)" <|
            \_ ->
                let
                    target =
                        stackAt "2C,3D,4C" (at 0 0)

                    rect =
                        WingOracle.wingBoardRect { target = target, side = Right }
                in
                rect.left
                    |> Expect.equal (3 * CardStack.stackPitch)
        , test "top aligns with target's top regardless of side" <|
            \_ ->
                let
                    target =
                        stackAt "2C,3D,4C" (at 50 150)

                    leftRect =
                        WingOracle.wingBoardRect { target = target, side = Left }

                    rightRect =
                        WingOracle.wingBoardRect { target = target, side = Right }
                in
                Expect.all
                    [ \_ -> leftRect.top |> Expect.equal 150
                    , \_ -> rightRect.top |> Expect.equal 150
                    ]
                    ()
        , test "left-side rect's right edge touches the target's left edge" <|
            \_ ->
                let
                    target =
                        stackAt "2C,3D,4C" (at 100 200)

                    rect =
                        WingOracle.wingBoardRect { target = target, side = Left }
                in
                (rect.left + rect.width)
                    |> Expect.equal 100
        ]



-- MAIN SUITE


suite : Test
suite =
    describe "WingOracle"
        [ suiteWingsForStack
        , suiteWingBoardRect
        ]
