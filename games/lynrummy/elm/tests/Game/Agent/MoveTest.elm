module Game.Agent.MoveTest exposing (suite)

{-| Tests for `Game.Agent.Move.describe` — the human-readable
DSL renderer. Mirrors the format of `python/bfs_solver.py`'s
`describe_move` so a plan reads identically across both
implementations.
-}

import Expect
import Game.Agent.Move as Move
    exposing
        ( ExtractVerb(..)
        , Move(..)
        , Side(..)
        , SourceBucket(..)
        )
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
    describe "Game.Agent.Move.describe"
        [ test "extract_absorb (peel) renders source + target + result" <|
            \_ ->
                let
                    move =
                        ExtractAbsorb
                            { verb = Peel
                            , source = [ card "5H", card "6H", card "7H", card "8H" ]
                            , extCard = card "5H"
                            , targetBefore = [ card "4H" ]
                            , targetBucketBefore = Trouble
                            , result = [ card "4H", card "5H" ]
                            , side = RightSide
                            , graduated = False
                            , spawned = []
                            }
                in
                Move.describe move
                    |> String.contains "peel 5H from HELPER [5H 6H 7H 8H], absorb onto trouble [4H] → [4H 5H]"
                    |> Expect.equal True
        , test "graduated extract gets [→COMPLETE] suffix" <|
            \_ ->
                let
                    move =
                        FreePull
                            { loose = card "8C"
                            , targetBefore = [ card "9C", card "TC" ]
                            , targetBucketBefore = Growing
                            , result = [ card "8C", card "9C", card "TC" ]
                            , side = LeftSide
                            , graduated = True
                            }
                in
                Move.describe move
                    |> String.contains "[→COMPLETE]"
                    |> Expect.equal True
        , test "push renders trouble → helper → result" <|
            \_ ->
                let
                    move =
                        Push
                            { troubleBefore = [ card "AC", card "2D" ]
                            , targetBefore = [ card "3S", card "4D", card "5C" ]
                            , result = [ card "AC", card "2D", card "3S", card "4D", card "5C" ]
                            , side = RightSide
                            }
                in
                Move.describe move
                    |> String.contains "push TROUBLE [AC 2D] onto HELPER [3S 4D 5C]"
                    |> Expect.equal True
        , test "splice renders both halves of the result" <|
            \_ ->
                let
                    move =
                        Splice
                            { loose = card "5D"
                            , source = [ card "3D", card "4D", card "5D", card "6D", card "7D", card "8D" ]
                            , k = 2
                            , side = LeftSide
                            , leftResult = [ card "3D", card "4D", card "5D" ]
                            , rightResult = [ card "5D", card "6D", card "7D", card "8D" ]
                            }
                in
                Move.describe move
                    |> String.contains "splice [5D] into HELPER"
                    |> Expect.equal True
        ]
