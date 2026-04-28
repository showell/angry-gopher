module Game.Agent.GeometryPlanTest exposing (suite)

{-| Tests for `Game.Agent.GeometryPlan.planActions`. Mirrors
`python/test_plan_merge_hand.py` for the merge-stack
analogue: in-place merges that fit get emitted as is;
merges whose result would violate get a pre-flight
`MoveStack` injected.
-}

import Expect
import Game.Agent.GeometryPlan as GeometryPlan
import Game.BoardActions as BoardActions
import Game.Rules.Card exposing (Card, OriginDeck(..))
import Game.CardStack exposing (BoardCard, BoardCardState(..), CardStack)
import Game.WireAction exposing (WireAction(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Rules.Card.cardFromLabel label DeckOne of
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


actionTags : List WireAction -> List String
actionTags =
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
    describe "Game.Agent.GeometryPlan.planActions"
        [ test "in-place merge with room: emit single merge_stack" <|
            \_ ->
                let
                    target =
                        stack 100 100 [ card "5H", card "6H", card "7H" ]

                    source =
                        stack 100 250 [ card "8H" ]

                    board =
                        [ target, source ]

                    actions =
                        [ MergeStack
                            { source = source
                            , target = target
                            , side = BoardActions.Right
                            }
                        ]
                in
                GeometryPlan.planActions board actions
                    |> actionTags
                    |> Expect.equal [ "merge_stack" ]
        , test "right-merge near right edge pre-moves the target" <|
            \_ ->
                let
                    -- Pin the target so close to the right edge
                    -- that adding more cards would overflow.
                    target =
                        stack 200 770 [ card "2C", card "3C", card "4C" ]

                    source =
                        stack 300 100 [ card "5C" ]

                    board =
                        [ target, source ]

                    actions =
                        [ MergeStack
                            { source = source
                            , target = target
                            , side = BoardActions.Right
                            }
                        ]
                in
                GeometryPlan.planActions board actions
                    |> actionTags
                    |> Expect.equal [ "move_stack", "merge_stack" ]
        , test "non-merge actions pass through unchanged" <|
            \_ ->
                let
                    src =
                        stack 100 100 [ card "5H", card "6H", card "7H", card "8H" ]

                    board =
                        [ src ]

                    actions =
                        [ Split { stack = src, cardIndex = 0 } ]
                in
                GeometryPlan.planActions board actions
                    |> actionTags
                    |> Expect.equal [ "split" ]
        ]
