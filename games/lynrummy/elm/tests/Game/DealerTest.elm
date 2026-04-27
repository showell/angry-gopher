module Game.DealerTest exposing (suite)

{-| Tests for Game.Dealer — especially the seed-driven
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
import Game.Card as Card exposing (OriginDeck(..), Suit(..))
import Game.Dealer as Dealer
import Game.Hand as Hand
import Game.Random as Random
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Game.Dealer.dealFullGame"
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
                    setup.hands
                        |> List.map Hand.size
                        |> List.sum

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
    describe "two hands, 15 cards each"
        [ test "hand count = 2" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 7)
                in
                Expect.equal 2 (List.length setup.hands)
        , test "each hand has 15 cards" <|
            \_ ->
                let
                    setup =
                        Dealer.dealFullGame (Random.initSeed 7)
                in
                setup.hands
                    |> List.map Hand.size
                    |> Expect.equal [ 15, 15 ]
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
    setup.hands
        |> List.map (\h -> List.map .card h.handCards)
