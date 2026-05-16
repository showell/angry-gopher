module Lib.DealerTest exposing (suite)

{-| Tests for Lib.Dealer — especially the seed-driven
`dealFullGame`, which is the offline-mode client's route to a
full initial state without any server round-trip.

Covered:

  - Card conservation: board + hands + deck = 104 total.
  - Each of the six initial stacks matches its shorthand exactly.
  - Both hands are 15 cards.
  - Determinism: same seed → same deal, every run.
  - Different seeds produce different deals (sanity check;
    theoretically could collide but vanishingly unlikely for
    any non-pathological seed pair).

-}

import Expect
import Lib.Rules.Card as Card exposing (OriginDeck(..), Suit(..))
import Lib.Dealer as Dealer
import Lib.Hand as Hand
import Lib.Random as Random
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Lib.Dealer.dealFullGame"
        [ cardConservation
        , stackShapes
        , handSizes
        , determinism
        , seedSensitivity
        ]


cardConservation : Test
cardConservation =
    test "board + hands + deck = 104 cards (no duplicates, no losses)" <|
        \_ ->
            let
                setup =
                    Dealer.dealFullGame (Random.initSeed 42)

                boardCount =
                    setup.board
                        |> List.map (\s -> List.length s.boardCards)
                        |> List.sum

                handsCount =
                    Hand.size setup.humanHand + Hand.size setup.agentHand

                deckCount =
                    List.length setup.deck
            in
            Expect.equal 104 (boardCount + handsCount + deckCount)


stackShapes : Test
stackShapes =
    describe "initial stacks match the six hardcoded shorthands"
        [ test "six stacks produced" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 42)
                in
                Expect.equal 6 (List.length setup.board)
        , test "stack sizes 4,4,3,3,3,6 (in row order)" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 42)
                in
                setup.board
                    |> List.map (\s -> List.length s.boardCards)
                    |> Expect.equal [ 4, 4, 3, 3, 3, 6 ]
        , test "first stack is K♠-A♠-2♠-3♠" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 42)

                    expected =
                        [ { value = Card.King, suit = Spade, originDeck = DeckOne }
                        , { value = Card.Ace, suit = Spade, originDeck = DeckOne }
                        , { value = Card.Two, suit = Spade, originDeck = DeckOne }
                        , { value = Card.Three, suit = Spade, originDeck = DeckOne }
                        ]
                in
                case List.head setup.board of
                    Just stack ->
                        stack.boardCards
                            |> List.map .card
                            |> Expect.equal expected

                    Nothing ->
                        Expect.fail "no first stack"
        ]


handSizes : Test
handSizes =
    describe "each hand has 15 cards"
        [ test "humanHand has 15 cards" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 7)
                in
                Hand.size setup.humanHand |> Expect.equal 15
        , test "agentHand has 15 cards" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 7)
                in
                Hand.size setup.agentHand |> Expect.equal 15
        ]


determinism : Test
determinism =
    test "same seed → identical deal across calls" <|
        \_ ->
            let
                a =
                    Dealer.dealFullGame (Random.initSeed 1234)

                b =
                    Dealer.dealFullGame (Random.initSeed 1234)
            in
            Expect.equal (handCards a) (handCards b)


seedSensitivity : Test
seedSensitivity =
    test "different seeds → different hands (sanity check)" <|
        \_ ->
            let
                a =
                    Dealer.dealFullGame (Random.initSeed 1)

                b =
                    Dealer.dealFullGame (Random.initSeed 999)
            in
            Expect.notEqual (handCards a) (handCards b)


{-| Extract both hands as card lists, for determinism checks.
-}
handCards : Dealer.GameSetup -> List (List Card.Card)
handCards setup =
    [ List.map .card setup.humanHand.handCards
    , List.map .card setup.agentHand.handCards
    ]
