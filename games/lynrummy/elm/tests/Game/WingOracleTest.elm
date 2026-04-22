module Game.WingOracleTest exposing (suite)

{-| Tests for `Game.WingOracle`. Two targets:

  - `wingsForStack` / `wingsForHandCard` — does the oracle
    offer the right merge targets + sides for a given source?
  - `wingBoardRect` — does the wing's computed board-frame
    rect match the positioning math that `Main.View.viewWingAt`
    uses at render time?

Added 2026-04-22 when a board-to-board merge silently failed
to land on a clearly-offered wing (the 234 + 567 case after a
split). See `users/steve/general/wing_hit_walkthrough.md` for
the pipeline breakdown.

-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.Card exposing (OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardLocation, CardStack)
import Game.WingOracle as WingOracle exposing (WingId)
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
            -- Tests build shorthands by hand; a typo will surface
            -- as a test failure with a clear message, not a
            -- runtime crash in production code.
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
                    board =
                        [ stackAt "2C,3D,4C" (at 100 200)
                        , stackAt "5H,6S,7H" (at 300 200)
                        ]

                    -- Source: dragging the 567 half.
                    wingsFor567 =
                        WingOracle.wingsForStack 1 board
                in
                wingsFor567
                    |> Expect.equal [ { stackIndex = 0, side = Right } ]
        , test "234 dragged toward 567 offers a LEFT wing on 567 (the other direction)" <|
            \_ ->
                let
                    board =
                        [ stackAt "2C,3D,4C" (at 100 200)
                        , stackAt "5H,6S,7H" (at 300 200)
                        ]
                in
                WingOracle.wingsForStack 0 board
                    |> Expect.equal [ { stackIndex = 1, side = Left } ]
        , test "no wings when a merge wouldn't form a valid group" <|
            \_ ->
                let
                    board =
                        -- Both stacks are sets, but "sets of different value"
                        -- don't merge — combining A's and 7's isn't valid.
                        [ stackAt "AC,AD,AH" (at 100 200)
                        , stackAt "7C,7D,7H" (at 300 200)
                        ]
                in
                WingOracle.wingsForStack 0 board
                    |> Expect.equal []
        , test "self is excluded even if it structurally equals another stack" <|
            \_ ->
                let
                    board =
                        [ stackAt "2C,3D,4C" (at 100 200) ]
                in
                WingOracle.wingsForStack 0 board
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
                        { stackIndex = 0, side = Right }
                in
                WingOracle.wingBoardRect wing target
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
                        { stackIndex = 0, side = Left }
                in
                WingOracle.wingBoardRect wing target
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
                        WingOracle.wingBoardRect { stackIndex = 0, side = Right } target
                in
                -- For a 3-card stack at (0, 0), the right wing's
                -- left edge is at 3 * stackPitch.
                rect.left
                    |> Expect.equal (3 * CardStack.stackPitch)
        , test "top aligns with target's top regardless of side" <|
            \_ ->
                let
                    target =
                        stackAt "2C,3D,4C" (at 50 150)

                    leftRect =
                        WingOracle.wingBoardRect { stackIndex = 0, side = Left } target

                    rightRect =
                        WingOracle.wingBoardRect { stackIndex = 0, side = Right } target
                in
                Expect.all
                    [ \_ -> leftRect.top |> Expect.equal 150
                    , \_ -> rightRect.top |> Expect.equal 150
                    ]
                    ()
        , test "rect fully encloses the target's left edge column when side = Left" <|
            \_ ->
                let
                    target =
                        stackAt "2C,3D,4C" (at 100 200)

                    rect =
                        WingOracle.wingBoardRect { stackIndex = 0, side = Left } target
                in
                -- The wing's right edge touches the target's left edge.
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
