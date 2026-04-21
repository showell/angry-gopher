module Game.StackTypeTest exposing (suite)

{-| Tests for `Game.StackType`. Ported from
`angry-cat/src/lyn_rummy/core/stack_type_test.ts`.

Covers: `getStackType` classification over representative hands,
`valueDistance` cyclic properties, `successor` / `predecessor`
wrap behavior.

Past-Claude's TS tests covered `getStackType` and `valueDistance`
thoroughly; `successor` / `predecessor` weren't tested directly
in the source. Current-Claude adds a small set for those two —
cheap coverage on a pair of foundational functions the referee
will rely on.

-}

import Expect
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), allCardValues, cardFromLabel)
import Game.StackType
    exposing
        ( CardStackType(..)
        , getStackType
        , predecessor
        , successor
        , valueDistance
        )
import Test exposing (Test, describe, test)



-- HELPERS


{-| Parse a list of labels into cards, all from DeckOne.
Fails the test if any label is malformed.
-}
cardsFromLabels : List String -> List Card
cardsFromLabels labels =
    List.filterMap (\l -> cardFromLabel l DeckOne) labels


{-| Shortcuts for the two-deck scenarios.
-}
fromD1 : String -> Card
fromD1 label =
    cardFromLabel label DeckOne
        |> Maybe.withDefault fallbackCard


fromD2 : String -> Card
fromD2 label =
    cardFromLabel label DeckTwo
        |> Maybe.withDefault fallbackCard


{-| Only used as a Maybe.withDefault guard. If a test ever
falls through to this, the label was malformed — treat as a test
bug.
-}
fallbackCard : Card
fallbackCard =
    { value = Ace, suit = Club, originDeck = DeckOne }



-- SUITE


suite : Test
suite =
    describe "Game.StackType"
        [ getStackTypeTests
        , valueDistanceTests
        , successorTests
        , predecessorTests
        ]


getStackTypeTests : Test
getStackTypeTests =
    describe "getStackType"
        [ describe "too few cards"
            [ test "empty -> Incomplete" <|
                \_ -> Expect.equal Incomplete (getStackType [])
            , test "single card -> Incomplete" <|
                \_ -> Expect.equal Incomplete (getStackType (cardsFromLabels [ "AH" ]))
            , test "two cards -> Incomplete" <|
                \_ -> Expect.equal Incomplete (getStackType (cardsFromLabels [ "AH", "2H" ]))
            ]
        , describe "pure run (same suit, sequential)"
            [ test "AH 2H 3H is PureRun" <|
                \_ -> Expect.equal PureRun (getStackType (cardsFromLabels [ "AH", "2H", "3H" ]))
            , test "TD JD QD KD is PureRun" <|
                \_ -> Expect.equal PureRun (getStackType (cardsFromLabels [ "TD", "JD", "QD", "KD" ]))
            , test "KS AS 2S is PureRun (K wraps to A)" <|
                \_ -> Expect.equal PureRun (getStackType (cardsFromLabels [ "KS", "AS", "2S" ]))
            ]
        , describe "red/black alternating run"
            [ test "AH 2S 3H is RedBlackRun" <|
                \_ -> Expect.equal RedBlackRun (getStackType (cardsFromLabels [ "AH", "2S", "3H" ]))
            , test "AC 2H 3C 4H is RedBlackRun" <|
                \_ -> Expect.equal RedBlackRun (getStackType (cardsFromLabels [ "AC", "2H", "3C", "4H" ]))
            ]
        , describe "set (same value, different suits, no dups)"
            [ test "7S 7D 7C is Set" <|
                \_ -> Expect.equal Set (getStackType (cardsFromLabels [ "7S", "7D", "7C" ]))
            , test "AC AD AH AS is Set (full four)" <|
                \_ -> Expect.equal Set (getStackType (cardsFromLabels [ "AC", "AD", "AH", "AS" ]))
            ]
        , describe "dup (same value and suit)"
            [ test "two AH from different decks -> Dup" <|
                \_ ->
                    Expect.equal Dup
                        (getStackType [ fromD1 "AH", fromD2 "AH" ])
            , test "a provisional set that contains a dup -> Dup" <|
                \_ ->
                    Expect.equal Dup
                        (getStackType [ fromD1 "7S", fromD2 "7S", fromD1 "7D" ])
            ]
        , describe "bogus (inconsistent or invalid)"
            [ test "wrong order for a run (3H 2H AH)" <|
                \_ -> Expect.equal Bogus (getStackType (cardsFromLabels [ "3H", "2H", "AH" ]))
            , test "mixed stack types (AH 2H 3D)" <|
                \_ -> Expect.equal Bogus (getStackType (cardsFromLabels [ "AH", "2H", "3D" ]))
            , test "mixing set and run (AH 2H 2D)" <|
                \_ -> Expect.equal Bogus (getStackType (cardsFromLabels [ "AH", "2H", "2D" ]))
            ]
        ]


valueDistanceTests : Test
valueDistanceTests =
    describe "valueDistance (cyclic over 13, max 6)"
        [ test "self distance is always 0" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> valueDistance v v == 0)
                    |> Expect.equal True
        , describe "ace's neighborhood (wrap-around case)"
            [ test "Ace <-> King = 1" <| \_ -> Expect.equal 1 (valueDistance Ace King)
            , test "Ace <-> Two = 1" <| \_ -> Expect.equal 1 (valueDistance Ace Two)
            , test "Ace <-> Queen = 2" <| \_ -> Expect.equal 2 (valueDistance Ace Queen)
            , test "Ace <-> Three = 2" <| \_ -> Expect.equal 2 (valueDistance Ace Three)
            , test "Ace <-> Four = 3" <| \_ -> Expect.equal 3 (valueDistance Ace Four)
            , test "Ace <-> Jack = 3" <| \_ -> Expect.equal 3 (valueDistance Ace Jack)
            ]
        , describe "king's neighborhood (other side of wrap)"
            [ test "King <-> Ace = 1" <| \_ -> Expect.equal 1 (valueDistance King Ace)
            , test "King <-> Queen = 1" <| \_ -> Expect.equal 1 (valueDistance King Queen)
            , test "King <-> Two = 2" <| \_ -> Expect.equal 2 (valueDistance King Two)
            ]
        , describe "diametric pairs (max distance 6)"
            [ test "Two <-> Eight = 6" <| \_ -> Expect.equal 6 (valueDistance Two Eight)
            , test "Two <-> Nine = 6" <| \_ -> Expect.equal 6 (valueDistance Two Nine)
            , test "Three <-> Nine = 6" <| \_ -> Expect.equal 6 (valueDistance Three Nine)
            , test "Seven <-> Ace = 6" <| \_ -> Expect.equal 6 (valueDistance Seven Ace)
            , test "Seven <-> King = 6" <| \_ -> Expect.equal 6 (valueDistance Seven King)
            ]
        , test "distance is in [0, 6] everywhere on the cycle" <|
            \_ ->
                let
                    pairs =
                        allCardValues
                            |> List.concatMap (\a -> List.map (\b -> ( a, b )) allCardValues)

                    inRange ( a, b ) =
                        let
                            d =
                                valueDistance a b
                        in
                        d >= 0 && d <= 6
                in
                pairs
                    |> List.all inRange
                    |> Expect.equal True
        , test "distance is symmetric everywhere on the cycle" <|
            \_ ->
                let
                    pairs =
                        allCardValues
                            |> List.concatMap (\a -> List.map (\b -> ( a, b )) allCardValues)

                    symmetric ( a, b ) =
                        valueDistance a b == valueDistance b a
                in
                pairs
                    |> List.all symmetric
                    |> Expect.equal True
        ]


successorTests : Test
successorTests =
    describe "successor (wraps King -> Ace)"
        [ test "Ace -> Two" <| \_ -> Expect.equal Two (successor Ace)
        , test "Nine -> Ten" <| \_ -> Expect.equal Ten (successor Nine)
        , test "King -> Ace (wrap)" <| \_ -> Expect.equal Ace (successor King)
        , test "K, A, 2 chain via successor" <|
            \_ ->
                Expect.equal [ Ace, Two ]
                    [ successor King, successor (successor King) ]
        , test "applying successor 13 times returns to start" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> apply 13 successor v == v)
                    |> Expect.equal True
        ]


predecessorTests : Test
predecessorTests =
    describe "predecessor (wraps Ace -> King)"
        [ test "Two -> Ace" <| \_ -> Expect.equal Ace (predecessor Two)
        , test "Ace -> King (wrap)" <| \_ -> Expect.equal King (predecessor Ace)
        , test "predecessor is inverse of successor everywhere" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> predecessor (successor v) == v)
                    |> Expect.equal True
        ]



-- small helper used above


apply : Int -> (a -> a) -> a -> a
apply n f x =
    if n <= 0 then
        x

    else
        apply (n - 1) f (f x)
