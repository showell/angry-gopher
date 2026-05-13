module Lib.RefereeTest exposing (suite)

{-| Tests for `Lib.Rules.Referee.validateTurnComplete`. The
mid-turn validator (`validateGameMove`) was retired 2026-05-13;
production guards moves at the gesture/drag layer
(`isCursorOverBoard`), so the mid-turn rule path no longer exists.

-}

import Expect
import Lib.Physics.BoardGeometry exposing (BoardBounds)
import Lib.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Lib.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , CardStack
        )
import Lib.Rules.Referee
    exposing
        ( RefereeStage(..)
        , validateTurnComplete
        )
import Test exposing (Test, describe, test)



-- HELPERS


bounds : BoardBounds
bounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


card : CardValue -> Suit -> OriginDeck -> Card
card v s d =
    { value = v, suit = s, originDeck = d }


bc : CardValue -> Suit -> BoardCard
bc v s =
    { card = card v s DeckOne, state = FirmlyOnBoard }


stack : List BoardCard -> Int -> Int -> CardStack
stack cards top left =
    { boardCards = cards, loc = { top = top, left = left } }



-- SUITE


suite : Test
suite =
    describe "Lib.Rules.Referee"
        [ turnCompleteTests
        ]


turnCompleteTests : Test
turnCompleteTests =
    describe "turn completion"
        [ test "clean board of valid stacks is accepted" <|
            \_ ->
                let
                    run =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10

                    set =
                        stack [ bc King Club, bc King Diamond, bc King Spade ] 10 200
                in
                validateTurnComplete [ run, set ] bounds
                    |> Expect.equal (Ok ())
        , test "incomplete 2-card stack at turn end is rejected (semantics)" <|
            \_ ->
                let
                    incomplete =
                        stack [ bc Ace Heart, bc Two Heart ] 10 10
                in
                case validateTurnComplete [ incomplete ] bounds of
                    Err err ->
                        Expect.equal Semantics err.stage

                    Ok _ ->
                        Expect.fail "expected semantics rejection, got Ok"
        , test "overlapping stacks at turn end are rejected (geometry)" <|
            \_ ->
                let
                    s1 =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10

                    s2 =
                        stack [ bc Seven Club, bc Seven Diamond, bc Seven Spade ] 10 10
                in
                case validateTurnComplete [ s1, s2 ] bounds of
                    Err err ->
                        Expect.equal Geometry err.stage

                    Ok _ ->
                        Expect.fail "expected geometry rejection, got Ok"
        , test "empty board is accepted at turn end" <|
            \_ ->
                validateTurnComplete [] bounds
                    |> Expect.equal (Ok ())
        ]
