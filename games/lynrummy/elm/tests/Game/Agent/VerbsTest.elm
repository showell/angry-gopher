module Game.Agent.VerbsTest exposing (suite)

{-| Tests for `Game.Agent.Verbs.moveToPrimitives`. Each test
hand-builds a small board + a Move and asserts on the
resulting WireAction sequence.

Mirrors `python/test_verbs.py`'s coverage: per move type, plus
post-board geometry sanity is covered separately by the
geometry tests (this module asserts only on move
decomposition).
-}

import Expect
import Game.Agent.Move as Move
    exposing
        ( ExtractVerb(..)
        , Move(..)
        , Side(..)
        , SourceBucket(..)
        , WhichEnd(..)
        )
import Game.Agent.Verbs as Verbs
import Game.BoardActions as BoardActions
import Game.Card exposing (Card, OriginDeck(..))
import Game.CardStack exposing (BoardCard, BoardCardState(..), CardStack)
import Game.WireAction exposing (WireAction(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Card.cardFromLabel label DeckOne of
        Just c ->
            c

        Nothing ->
            Debug.todo ("bad label: " ++ label)


boardCard : Card -> BoardCard
boardCard c =
    { card = c, state = FirmlyOnBoard }


stack : Int -> Int -> List Card -> CardStack
stack top left cards =
    { boardCards = List.map boardCard cards
    , loc = { top = top, left = left }
    }


actions : List WireAction -> List String
actions =
    List.map actionTag


actionTag : WireAction -> String
actionTag a =
    case a of
        Split _ ->
            "split"

        MergeStack _ ->
            "merge_stack"

        MergeHand _ ->
            "merge_hand"

        MoveStack _ ->
            "move_stack"

        PlaceHand _ ->
            "place_hand"

        CompleteTurn ->
            "complete_turn"

        Undo ->
            "undo"


suite : Test
suite =
    describe "Game.Agent.Verbs.moveToPrimitives"
        [ test "peel-left-edge: 5H from [5H 6H 7H 8H] → split + merge" <|
            \_ ->
                let
                    board =
                        [ stack 100 100 [ card "5H", card "6H", card "7H", card "8H" ]
                        , stack 100 400 [ card "4H" ]
                        ]

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

                    prims =
                        Verbs.moveToPrimitives board move
                in
                actions prims
                    |> Expect.equal [ "split", "merge_stack" ]
        , test "free_pull: loose singleton → single merge_stack" <|
            \_ ->
                let
                    board =
                        [ stack 100 100 [ card "5H", card "6H", card "7H" ]
                        , stack 200 100 [ card "4H" ]
                        ]

                    move =
                        FreePull
                            { loose = card "4H"
                            , targetBefore = [ card "5H", card "6H", card "7H" ]
                            , targetBucketBefore = Growing
                            , result = [ card "4H", card "5H", card "6H", card "7H" ]
                            , side = LeftSide
                            , graduated = True
                            }

                    prims =
                        Verbs.moveToPrimitives board move
                in
                actions prims
                    |> Expect.equal [ "merge_stack" ]
        , test "push: 2-partial trouble → single merge_stack" <|
            \_ ->
                let
                    board =
                        [ stack 100 100 [ card "9C", card "TC", card "JC" ]
                        , stack 200 100 [ card "QC", card "KC" ]
                        ]

                    move =
                        Push
                            { troubleBefore = [ card "QC", card "KC" ]
                            , targetBefore = [ card "9C", card "TC", card "JC" ]
                            , result = [ card "9C", card "TC", card "JC", card "QC", card "KC" ]
                            , side = RightSide
                            }

                    prims =
                        Verbs.moveToPrimitives board move
                in
                actions prims
                    |> Expect.equal [ "merge_stack" ]
        , test "splice: split + merge" <|
            \_ ->
                let
                    src =
                        [ card "3D", card "4D", card "5D", card "6D", card "7D", card "8D" ]

                    board =
                        [ stack 100 100 src
                        , stack 200 400 [ card "5D" ]
                        ]

                    -- Note the loose's identity is by its own
                    -- card record; we use a deck-2 5D so it's
                    -- distinguishable from the run's 5D.
                    looseCard =
                        case Game.Card.cardFromLabel "5D" DeckTwo of
                            Just c ->
                                c

                            Nothing ->
                                Debug.todo "bad label: 5D"

                    boardWithLoose =
                        [ stack 100 100 src
                        , stack 200 400 [ looseCard ]
                        ]

                    move =
                        Splice
                            { loose = looseCard
                            , source = src
                            , k = 2
                            , side = LeftSide
                            , leftResult = [ card "3D", card "4D", looseCard ]
                            , rightResult = [ card "5D", card "6D", card "7D", card "8D" ]
                            }

                    prims =
                        Verbs.moveToPrimitives boardWithLoose move
                in
                actions prims
                    |> Expect.equal [ "split", "merge_stack" ]
        , test "shift (8C-pops-JC): donor split + source split + 2 merges" <|
            \_ ->
                let
                    board =
                        [ stack 100 100 [ card "9C", card "TC", card "JC" ]
                        , stack 200 100 [ card "8D", card "8S", card "8H", card "8C" ]
                        , stack 300 400 [ card "QH" ]
                        ]

                    move =
                        Shift
                            { source = [ card "9C", card "TC", card "JC" ]
                            , donor = [ card "8D", card "8S", card "8H", card "8C" ]
                            , stolen = card "JC"
                            , pCard = card "8C"
                            , whichEnd = RightEnd
                            , newSource = [ card "8C", card "9C", card "TC" ]
                            , newDonor = [ card "8D", card "8S", card "8H" ]
                            , targetBefore = [ card "QH" ]
                            , targetBucketBefore = Trouble
                            , merged = [ card "QH", card "JC" ]
                            , side = RightSide
                            , graduated = False
                            }

                    prims =
                        Verbs.moveToPrimitives board move
                in
                actions prims
                    |> Expect.equal [ "split", "split", "merge_stack", "merge_stack" ]
        , test "steal-from-set: ext + remnant fully dismantled into 3 singletons" <|
            -- Regression for the puzzle-1 stall: steal AC from
            -- [AC AD AH] used to emit only one split, leaving
            -- [AD AH] as a pair and stalling subsequent moves
            -- that wanted to push [AD] / [AH] independently.
            -- Expected: split off AC, split the remnant pair,
            -- merge AC onto target. Three primitives total.
            \_ ->
                let
                    board =
                        [ stack 100 100 [ card "AC", card "AD", card "AH" ]
                        , stack 200 100 [ card "2D", card "3S" ]
                        ]

                    move =
                        ExtractAbsorb
                            { verb = Steal
                            , source = [ card "AC", card "AD", card "AH" ]
                            , extCard = card "AC"
                            , targetBefore = [ card "2D", card "3S" ]
                            , targetBucketBefore = Trouble
                            , result = [ card "AC", card "2D", card "3S" ]
                            , side = LeftSide
                            , graduated = True
                            , spawned = [ [ card "AD" ], [ card "AH" ] ]
                            }

                    prims =
                        Verbs.moveToPrimitives board move
                in
                actions prims
                    |> Expect.equal [ "split", "split", "merge_stack" ]
        ]
