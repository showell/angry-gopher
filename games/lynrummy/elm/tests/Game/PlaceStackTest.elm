module Game.PlaceStackTest exposing (suite)

{-| Tests for `Game.PlaceStack`. Ported from
`angry-cat/src/lyn_rummy/game/place_stack_test.ts`.
-}

import Expect
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardFromLabel)
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , BoardLocation
        , CardStack
        )
import Game.PlaceStack as PS exposing (BoardBounds)
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


defaultBounds : BoardBounds
defaultBounds =
    { maxWidth = 1200
    , maxHeight = 540
    , margin = 4
    , step = 10
    }


boundsWith : (BoardBounds -> BoardBounds) -> BoardBounds
boundsWith f =
    f defaultBounds



-- OVERLAP CHECK (mirrors the TS assertion style)


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
        , emptyBoardTests
        , oneStackNoOverlapTests
        , rowOfStacksTests
        , scatteredBoardTests
        , noFitFallbackTests
        , marginTests
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


emptyBoardTests : Test
emptyBoardTests =
    describe "empty board"
        [ test "returns origin (0, 0)" <|
            \_ ->
                let
                    loc =
                        PS.findOpenLoc [] 3 defaultBounds
                in
                Expect.all
                    [ \_ -> Expect.equal 0 loc.top
                    , \_ -> Expect.equal 0 loc.left
                    ]
                    ()
        ]


oneStackNoOverlapTests : Test
oneStackNoOverlapTests =
    describe "one stack at top-left"
        [ test "placer returns a non-overlapping loc" <|
            \_ ->
                let
                    existing =
                        [ stackAt 0 0 5 ]

                    loc =
                        PS.findOpenLoc existing 3 defaultBounds
                in
                Expect.equal False (overlapsAny loc 3 existing)
        ]


rowOfStacksTests : Test
rowOfStacksTests =
    describe "row of stacks at top"
        [ test "placer returns a non-overlapping loc" <|
            \_ ->
                let
                    existing =
                        [ stackAt 0 0 4
                        , stackAt 0 200 4
                        , stackAt 0 400 4
                        ]

                    loc =
                        PS.findOpenLoc existing 3 defaultBounds
                in
                Expect.equal False (overlapsAny loc 3 existing)
        ]


scatteredBoardTests : Test
scatteredBoardTests =
    describe "tightly packed board"
        [ test "finds somewhere that fits" <|
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
                        PS.findOpenLoc existing 3 defaultBounds
                in
                Expect.equal False (overlapsAny loc 3 existing)
        ]


noFitFallbackTests : Test
noFitFallbackTests =
    describe "no-fit fallback"
        [ test "5-card stack won't fit in 50x50; fallback = {top=10, left=0}" <|
            \_ ->
                let
                    tight =
                        { maxWidth = 50, maxHeight = 50, margin = 0, step = 10 }

                    loc =
                        PS.findOpenLoc [] 5 tight
                in
                Expect.all
                    [ \_ -> Expect.equal 0 loc.left
                    , \_ -> Expect.equal 10 loc.top
                    ]
                    ()
        ]


marginTests : Test
marginTests =
    describe "margin separates stacks"
        [ test "big margin does not return closer than no margin" <|
            \_ ->
                let
                    existing =
                        [ stackAt 0 0 3 ]

                    noMargin =
                        PS.findOpenLoc existing 3 (boundsWith (\b -> { b | margin = 0 }))

                    bigMargin =
                        PS.findOpenLoc existing 3 (boundsWith (\b -> { b | margin = 20 }))

                    noDist =
                        abs noMargin.left + abs noMargin.top

                    bigDist =
                        abs bigMargin.left + abs bigMargin.top
                in
                if bigDist >= noDist then
                    Expect.pass

                else
                    Expect.fail
                        ("big margin ("
                            ++ String.fromInt bigDist
                            ++ ") should not be closer than no margin ("
                            ++ String.fromInt noDist
                            ++ ")"
                        )
        ]
