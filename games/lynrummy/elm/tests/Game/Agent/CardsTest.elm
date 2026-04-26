module Game.Agent.CardsTest exposing (suite)

{-| Tests for `Game.Agent.Cards` — predicates the BFS
planner consumes. Mirrors the cases in
`python/beginner.py` for `partial_ok` and `neighbors` plus
the legal-stack filter atop `Game.StackType.getStackType`.
-}

import Expect
import Game.Agent.Cards as Cards
import Game.Card exposing (Card, OriginDeck(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Card.cardFromLabel label DeckOne of
        Just c ->
            c

        Nothing ->
            Debug.todo ("bad label: " ++ label)


suite : Test
suite =
    describe "Game.Agent.Cards"
        [ describe "isLegalStack"
            [ test "3-set classifies legal" <|
                \_ ->
                    Cards.isLegalStack
                        [ card "5C", card "5D", card "5S" ]
                        |> Expect.equal True
            , test "3-card pure run classifies legal" <|
                \_ ->
                    Cards.isLegalStack
                        [ card "5H", card "6H", card "7H" ]
                        |> Expect.equal True
            , test "3-card rb-run classifies legal" <|
                \_ ->
                    Cards.isLegalStack
                        [ card "5H", card "6S", card "7H" ]
                        |> Expect.equal True
            , test "2-card stack is not yet legal" <|
                \_ ->
                    Cards.isLegalStack
                        [ card "5H", card "6H" ]
                        |> Expect.equal False
            , test "wraparound K-A-2 pure run is legal" <|
                \_ ->
                    Cards.isLegalStack
                        [ card "KH", card "AH", card "2H" ]
                        |> Expect.equal True
            ]
        , describe "isPartialOk"
            [ test "empty stack is OK" <|
                \_ -> Cards.isPartialOk [] |> Expect.equal True
            , test "singleton is OK" <|
                \_ ->
                    Cards.isPartialOk [ card "5H" ]
                        |> Expect.equal True
            , test "consecutive same-suit pair is OK (pure-run partial)" <|
                \_ ->
                    Cards.isPartialOk [ card "5H", card "6H" ]
                        |> Expect.equal True
            , test "consecutive opposite-color pair is OK (rb-run partial)" <|
                \_ ->
                    Cards.isPartialOk [ card "5H", card "6C" ]
                        |> Expect.equal True
            , test "same-value distinct-suit pair is OK (set partial)" <|
                \_ ->
                    Cards.isPartialOk [ card "5H", card "5C" ]
                        |> Expect.equal True
            , test "non-consecutive pair is NOT ok" <|
                \_ ->
                    Cards.isPartialOk [ card "5H", card "9H" ]
                        |> Expect.equal False
            , test "consecutive same-color (different suits) NOT ok" <|
                \_ ->
                    Cards.isPartialOk [ card "5H", card "6D" ]
                        |> Expect.equal False
            , test "3+ legal stack delegates to isLegalStack" <|
                \_ ->
                    Cards.isPartialOk
                        [ card "5H", card "6H", card "7H" ]
                        |> Expect.equal True
            ]
        , describe "neighbors"
            [ test "5H neighbors include 4H and 6H (pure-run)" <|
                \_ ->
                    let
                        ns =
                            Cards.neighbors (card "5H")

                        h4 =
                            ( (card "4H").value, (card "4H").suit )

                        h6 =
                            ( (card "6H").value, (card "6H").suit )
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (List.member h4 ns)
                        , \_ -> Expect.equal True (List.member h6 ns)
                        ]
                        ()
            , test "5H neighbors include opposite-color ±1 (rb-run)" <|
                \_ ->
                    let
                        ns =
                            Cards.neighbors (card "5H")

                        c4 =
                            ( (card "4C").value, (card "4C").suit )

                        s6 =
                            ( (card "6S").value, (card "6S").suit )
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (List.member c4 ns)
                        , \_ -> Expect.equal True (List.member s6 ns)
                        ]
                        ()
            , test "5H neighbors include 5C, 5D, 5S (set partners)" <|
                \_ ->
                    let
                        ns =
                            Cards.neighbors (card "5H")

                        c5 =
                            ( (card "5C").value, (card "5C").suit )

                        d5 =
                            ( (card "5D").value, (card "5D").suit )

                        s5 =
                            ( (card "5S").value, (card "5S").suit )
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (List.member c5 ns)
                        , \_ -> Expect.equal True (List.member d5 ns)
                        , \_ -> Expect.equal True (List.member s5 ns)
                        ]
                        ()
            , test "5H neighbors do NOT include 5H itself" <|
                \_ ->
                    let
                        ns =
                            Cards.neighbors (card "5H")

                        h5 =
                            ( (card "5H").value, (card "5H").suit )
                    in
                    List.member h5 ns
                        |> Expect.equal False
            ]
        ]
