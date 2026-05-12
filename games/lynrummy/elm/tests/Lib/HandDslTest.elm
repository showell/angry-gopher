module Lib.HandDslTest exposing (suite)

import Expect
import Lib.CardStack exposing (HandCard, HandCardState(..))
import Lib.Hand exposing (Hand)
import Lib.HandDsl as HandDsl
import Lib.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "HandDsl"
        [ describe "formatHandBody"
            [ test "empty hand → empty string" <|
                \_ ->
                    HandDsl.formatHandBody { handCards = [] }
                        |> Expect.equal ""
            , test "single suit → one row, sorted by value" <|
                \_ ->
                    HandDsl.formatHandBody (handOf [ hc Jack Heart, hc Two Heart, hc Five Heart ])
                        |> Expect.equal "  2♥ 5♥ J♥"
            , test "multiple suits → rows in UI order (Heart, Spade, Diamond, Club)" <|
                \_ ->
                    HandDsl.formatHandBody
                        (handOf
                            [ hc Seven Club
                            , hc King Spade
                            , hc Three Heart
                            , hc Ten Diamond
                            ]
                        )
                        |> Expect.equal
                            ("  3♥\n"
                                ++ "  K♠\n"
                                ++ "  T♦\n"
                                ++ "  7♣"
                            )
            , test "empty suits are skipped" <|
                \_ ->
                    HandDsl.formatHandBody (handOf [ hc Two Heart, hc Three Club ])
                        |> Expect.equal "  2♥\n  3♣"
            ]
        , describe "parseHandBody"
            [ test "empty input → empty hand" <|
                \_ ->
                    HandDsl.parseHandBody "" |> Expect.equal (Ok { handCards = [] })
            , test "collects all cards regardless of line splits" <|
                \_ ->
                    HandDsl.parseHandBody "  A♥ 5♥\n  K♠"
                        |> Result.map (.handCards >> List.map .card)
                        |> Expect.equal
                            (Ok [ card Ace Heart, card Five Heart, card King Spade ])
            , test "tolerates ASCII suits" <|
                \_ ->
                    HandDsl.parseHandBody "  AH 5H\n  KS"
                        |> Result.map (.handCards >> List.map .card)
                        |> Expect.equal
                            (Ok [ card Ace Heart, card Five Heart, card King Spade ])
            , test "honors deck-2 suffix" <|
                \_ ->
                    HandDsl.parseHandBody "  K♥ K♥'"
                        |> Result.map (.handCards >> List.map (.card >> .originDeck))
                        |> Expect.equal (Ok [ DeckOne, DeckTwo ])
            , test "all parsed cards are HandNormal" <|
                \_ ->
                    HandDsl.parseHandBody "  A♥ K♠"
                        |> Result.map (.handCards >> List.map .state)
                        |> Expect.equal (Ok [ HandNormal, HandNormal ])
            ]
        , describe "format ∘ parse round-trip"
            [ test "multi-suit hand round-trips byte-identical" <|
                \_ ->
                    let
                        body =
                            "  2♥ 5♥ J♥\n  A♠ 3♠ K♠\n  T♦\n  7♣ 9♣"
                    in
                    HandDsl.parseHandBody body
                        |> Result.map HandDsl.formatHandBody
                        |> Expect.equal (Ok body)
            , test "unsorted ASCII parse re-emits sorted unicode" <|
                \_ ->
                    HandDsl.parseHandBody "  KH 2H 5H"
                        |> Result.map HandDsl.formatHandBody
                        |> Expect.equal (Ok "  2♥ 5♥ K♥")
            ]
        ]


handOf : List HandCard -> Hand
handOf cards =
    { handCards = cards }


hc : CardValue -> Suit -> HandCard
hc v s =
    { card = card v s, state = HandNormal }


card : CardValue -> Suit -> Card
card v s =
    { value = v, suit = s, originDeck = DeckOne }
