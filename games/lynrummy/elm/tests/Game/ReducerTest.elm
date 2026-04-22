module Game.ReducerTest exposing (suite)

{-| Tests for `Game.Reducer.applyAction`. Each action type
gets a transition test; a longer test sequences several actions
and checks end-state. CompleteTurn / Undo verify they are
no-ops here (turn-logic handled elsewhere).
-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (BoardCard, BoardCardState(..), CardStack, HandCardState(..))
import Game.Hand as Hand
import Game.Reducer as Reducer
import Game.WireAction exposing (WireAction(..))
import Test exposing (Test, describe, test)


{-| Return the CardStack at index idx of the given state's board.
Used to build wire-layer references for tests. -}
stackAt : Int -> Reducer.State -> CardStack
stackAt idx state =
    state.board
        |> List.drop idx
        |> List.head
        |> Maybe.withDefault
            -- should never happen for indices we use in tests
            { boardCards = [], loc = { top = 0, left = 0 } }


{-| A synthetic ghost CardStack that no real board will match. -}
ghostStack : CardStack
ghostStack =
    { boardCards =
        [ { card = { value = Ten, suit = Club, originDeck = DeckOne }
          , state = FirmlyOnBoard
          }
        ]
    , loc = { top = 9999, left = 9999 }
    }


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
                                (Split { stack = stackAt 0 before, cardIndex = 2 })
                                before
                    in
                    List.length after.board
                        |> Expect.equal (List.length before.board + 1)
            ]
        , describe "MoveStack"
            [ test "updates loc of target stack" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        newLoc =
                            { top = 300, left = 400 }

                        after =
                            Reducer.applyAction
                                (MoveStack { stack = stackAt 0 before, newLoc = newLoc })
                                before

                        -- Moved stack is appended at the end of
                        -- the board list (applyChange semantics).
                        movedLoc =
                            after.board
                                |> List.reverse
                                |> List.head
                                |> Maybe.map .loc
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

                        -- Stack index 3 in the opening board is "7S,7D,7C".
                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        after =
                            Reducer.applyAction
                                (MergeHand
                                    { handCard = card7H
                                    , target = stackAt 3 before
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
            [ test "Split on a ghost stack is a no-op" <|
                \_ ->
                    Reducer.applyAction
                        (Split { stack = ghostStack, cardIndex = 0 })
                        Reducer.initialState
                        |> Expect.equal Reducer.initialState
            , test "MoveStack on a ghost stack is a no-op" <|
                \_ ->
                    Reducer.applyAction
                        (MoveStack { stack = ghostStack, newLoc = { top = 10, left = 10 } })
                        Reducer.initialState
                        |> Expect.equal Reducer.initialState
            , test "MergeHand with a card not in hand is a no-op" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        notInHand =
                            { value = Ace, suit = Spade, originDeck = DeckTwo }
                    in
                    Reducer.applyAction
                        (MergeHand
                            { handCard = notInHand
                            , target = stackAt 3 before
                            , side = Right
                            }
                        )
                        before
                        |> Expect.equal before
            ]
        , describe "sequenced actions"
            [ test "split then move applies in order" <|
                \_ ->
                    let
                        start =
                            Reducer.initialState

                        step1 =
                            Reducer.applyAction
                                (Split { stack = stackAt 0 start, cardIndex = 2 })
                                start

                        -- After the split, one of the halves is at
                        -- the END of the list (applyChange appends).
                        -- Use the first half (at index 0) as the
                        -- reference for the move.
                        step2 =
                            Reducer.applyAction
                                (MoveStack
                                    { stack = stackAt 0 step1
                                    , newLoc = { top = 500, left = 400 }
                                    }
                                )
                                step1
                    in
                    List.length step2.board
                        |> Expect.equal (List.length start.board + 1)
            ]
        ]
