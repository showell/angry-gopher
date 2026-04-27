module Game.PlaceStackTest exposing (suite)

{-| Tests for `Game.PlaceStack`. Two layers:

1. Property tests — placer never lands on top of an existing
   stack, regardless of board shape.
2. Specific-loc tests — exact (top, left) values that
   python/geometry.py::find_open_loc produces for the same
   inputs. These are the parity oracle: any drift from
   Python flags here.

The Python oracle values are independently confirmed by
running:

    python3 -c "import sys; sys.path.insert(0, 'games/lynrummy/python');
                import geometry as g; print(g.find_open_loc([], 3))"

(and substituting other inputs).
-}

import Expect
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardFromLabel)
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , BoardLocation
        , CardStack
        )
import Game.PlaceStack as PS
import Test exposing (Test, describe, test)



-- HELPERS


fallback : Card
fallback =
    { value = Ace, suit = Club, originDeck = DeckOne }


card : String -> Card
card label =
    cardFromLabel label DeckOne |> Maybe.withDefault fallback


stackAt : Int -> Int -> Int -> CardStack
stackAt top left cardCount =
    let
        labels =
            [ "AH", "2H", "3H", "4H", "5H", "6H", "7H", "8H", "9H", "TH", "JH", "QH" ]
                |> List.take cardCount
    in
    { boardCards =
        List.map
            (\l -> { card = card l, state = FirmlyOnBoard })
            labels
    , loc = { top = top, left = left }
    }


overlapsAny : BoardLocation -> Int -> List CardStack -> Bool
overlapsAny loc newCards existing =
    let
        newW =
            PS.stackWidth newCards

        newH =
            40
    in
    List.any
        (\ex ->
            let
                exW =
                    PS.stackWidth (List.length ex.boardCards)

                overlapX =
                    loc.left < ex.loc.left + exW && loc.left + newW > ex.loc.left

                overlapY =
                    loc.top < ex.loc.top + 40 && loc.top + newH > ex.loc.top
            in
            overlapX && overlapY
        )
        existing



-- SUITE


suite : Test
suite =
    describe "Game.PlaceStack"
        [ stackWidthTests
        , emptyBoardOracleTest
        , preferredOriginOracleTest
        , noOverlapPropertyTests
        ]


stackWidthTests : Test
stackWidthTests =
    describe "stackWidth"
        [ test "0 cards -> 0" <| \_ -> Expect.equal 0 (PS.stackWidth 0)
        , test "1 card -> CARD_WIDTH = 27" <| \_ -> Expect.equal 27 (PS.stackWidth 1)
        , test "2 cards -> 27 + 33" <| \_ -> Expect.equal (27 + 33) (PS.stackWidth 2)
        , test "3 cards -> 27 + 33*2" <| \_ -> Expect.equal (27 + 33 * 2) (PS.stackWidth 3)
        , test "12 cards -> 27 + 33*11" <| \_ -> Expect.equal (27 + 33 * 11) (PS.stackWidth 12)
        ]


emptyBoardOracleTest : Test
emptyBoardOracleTest =
    test "empty board → BOARD_START + ANTI_ALIGN = (26, 26)" <|
        \_ ->
            PS.findOpenLoc [] 3
                |> Expect.equal { top = 26, left = 26 }


preferredOriginOracleTest : Test
preferredOriginOracleTest =
    test "one-stack board → preferred origin (52, 92) per Python oracle" <|
        \_ ->
            PS.findOpenLoc [ stackAt 0 0 5 ] 3
                |> Expect.equal { top = 92, left = 52 }


noOverlapPropertyTests : Test
noOverlapPropertyTests =
    describe "placer never overlaps existing stacks"
        [ test "row of stacks at top" <|
            \_ ->
                let
                    existing =
                        [ stackAt 0 0 4
                        , stackAt 0 200 4
                        , stackAt 0 400 4
                        ]

                    loc =
                        PS.findOpenLoc existing 3
                in
                Expect.equal False (overlapsAny loc 3 existing)
        , test "scattered packed board" <|
            \_ ->
                let
                    existing =
                        [ stackAt 0 0 6
                        , stackAt 0 300 4
                        , stackAt 80 0 5
                        , stackAt 80 300 3
                        , stackAt 160 0 7
                        , stackAt 160 350 4
                        ]

                    loc =
                        PS.findOpenLoc existing 3
                in
                Expect.equal False (overlapsAny loc 3 existing)
        ]
