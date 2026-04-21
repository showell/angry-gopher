module Game.ReducerTest exposing (suite)

{-| Tests for `Game.Reducer.applyAction`. Each action type
gets a transition test; a longer test sequences several actions
and checks end-state. CompleteTurn / Undo verify they are
no-ops here (turn-logic handled elsewhere).
-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (CardStack, HandCardState(..))
import Game.Hand as Hand
import Game.Reducer as Reducer
import Game.WireAction exposing (WireAction(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Reducer.applyAction"
        [ describe "Split"
            [ test "splits stack 0 (KS,AS,2S,3S) at index 2 → two stacks replace one" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        after =
                            Reducer.applyAction
                                (Split { stackIndex = 0, cardIndex = 2 })
                                before
                    in
                    List.length after.board
                        |> Expect.equal (List.length before.board + 1)
            ]
        , describe "MoveStack"
            [ test "updates loc of target stack" <|
                \_ ->
                    let
                        newLoc =
                            { top = 300, left = 400 }

                        after =
                            Reducer.applyAction
                                (MoveStack { stackIndex = 0, newLoc = newLoc })
                                Reducer.initialState

                        movedLoc =
                            after.board
                                |> List.drop 0
                                |> List.head
                                -- Last stack in the board is the moved one
                                -- (applyChange appends; original is removed)
                                |> always
                                    (after.board
                                        |> List.reverse
                                        |> List.head
                                        |> Maybe.map .loc
                                    )
                    in
                    movedLoc
                        |> Expect.equal (Just newLoc)
            ]
        , describe "PlaceHand"
            [ test "removes 7H from hand and adds a singleton to the board" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        after =
                            Reducer.applyAction
                                (PlaceHand { handCard = card7H, loc = { top = 400, left = 500 } })
                                before
                    in
                    Expect.all
                        [ \a -> Hand.size a.hand |> Expect.equal (Hand.size before.hand - 1)
                        , \a -> List.length a.board |> Expect.equal (List.length before.board + 1)
                        ]
                        after
            ]
        , describe "MergeHand"
            [ test "7H onto the 7S,7D,7C set (right side) → set grows by 1, hand shrinks by 1" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        -- Stack index 3 in the opening board is "7S,7D,7C"
                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        after =
                            Reducer.applyAction
                                (MergeHand
                                    { handCard = card7H
                                    , targetStack = 3
                                    , side = Right
                                    }
                                )
                                before
                    in
                    Expect.all
                        [ \a -> Hand.size a.hand |> Expect.equal (Hand.size before.hand - 1)
                        , \a -> List.length a.board |> Expect.equal (List.length before.board)
                        ]
                        after
            ]
        , describe "no-ops for turn-logic actions (not modeled in Replay)"
            [ test "CompleteTurn is a no-op" <|
                \_ ->
                    Reducer.applyAction CompleteTurn Reducer.initialState
                        |> Expect.equal Reducer.initialState
            , test "Undo is a no-op (snapshots come later)" <|
                \_ ->
                    Reducer.applyAction Undo Reducer.initialState
                        |> Expect.equal Reducer.initialState
            ]
        , describe "silent pass-through on invalid references"
            [ test "Split on nonexistent stack index is a no-op" <|
                \_ ->
                    Reducer.applyAction
                        (Split { stackIndex = 99, cardIndex = 0 })
                        Reducer.initialState
                        |> Expect.equal Reducer.initialState
            , test "MoveStack on nonexistent stack index is a no-op" <|
                \_ ->
                    Reducer.applyAction
                        (MoveStack { stackIndex = 99, newLoc = { top = 10, left = 10 } })
                        Reducer.initialState
                        |> Expect.equal Reducer.initialState
            , test "MergeHand with a card not in hand is a no-op" <|
                \_ ->
                    let
                        notInHand =
                            { value = Ace, suit = Spade, originDeck = DeckTwo }
                    in
                    Reducer.applyAction
                        (MergeHand
                            { handCard = notInHand
                            , targetStack = 3
                            , side = Right
                            }
                        )
                        Reducer.initialState
                        |> Expect.equal Reducer.initialState
            ]
        , describe "sequenced actions"
            [ test "split then move applies in order" <|
                \_ ->
                    let
                        start =
                            Reducer.initialState

                        step1 =
                            Reducer.applyAction
                                (Split { stackIndex = 0, cardIndex = 2 })
                                start

                        step2 =
                            Reducer.applyAction
                                (MoveStack
                                    { stackIndex = 0
                                    , newLoc = { top = 500, left = 400 }
                                    }
                                )
                                step1
                    in
                    List.length step2.board
                        |> Expect.equal (List.length start.board + 1)
            ]
        ]
