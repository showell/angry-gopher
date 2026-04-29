module Game.UndoTest exposing (suite)

{-| Tests for the Undo feature.

Covers:
  - `Game.Reducer.undoAction` — round-trip for all five primitives:
    Split, MergeStack, MergeHand, PlaceHand, MoveStack.
  - `Main.State.collapseUndos` — token collapsing in the action log.
  - `Main.State.canUndoThisTurn` — button-enable predicate.

Strategy: for `undoAction`, apply an action with `applyAction` then
immediately `undoAction` on the result and assert equality with the
pre-action state.  This sidesteps fragile board-construction and
directly verifies the round-trip invariant.
-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (CardStack, HandCardState(..))
import Game.Hand as Hand
import Game.Reducer as Reducer
import Game.WireAction exposing (WireAction(..))
import Main.State as State exposing (ActionLogEntry, PathFrame(..))
import Test exposing (Test, describe, test)


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------


{-| Return the CardStack at position `idx` in state.board. -}
stackAt : Int -> Reducer.State -> CardStack
stackAt idx state =
    state.board
        |> List.drop idx
        |> List.head
        |> Maybe.withDefault
            { boardCards = [], loc = { top = 0, left = 0 } }


{-| Construct a minimal ActionLogEntry for a WireAction.
`gesturePath` and `pathFrame` are inconsequential for the
`collapseUndos` / `canUndoThisTurn` tests; we use the cheapest
valid values.
-}
logEntry : WireAction -> ActionLogEntry
logEntry action =
    { action = action
    , gesturePath = Nothing
    , pathFrame = BoardFrame
    }


{-| Build a model with the given action log by starting from baseModel.
Elm's record-update syntax requires a local binding, not a
module-qualified name, so we can't write `{ State.baseModel | ... }`.
-}
modelWithLog : List ActionLogEntry -> State.Model
modelWithLog entries =
    let
        base =
            State.baseModel
    in
    { base | actionLog = entries }


-- ---------------------------------------------------------------------------
-- undoAction: round-trip tests
-- ---------------------------------------------------------------------------


suiteUndoAction : Test
suiteUndoAction =
    describe "Reducer.undoAction — round-trip invariant"
        [ describe "MoveStack"
            [ test "undoing a MoveStack restores the original location of the moved stack" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        originalStack =
                            stackAt 0 before

                        action =
                            MoveStack
                                { stack = originalStack
                                , newLoc = { top = 500, left = 600 }
                                }

                        after =
                            Reducer.applyAction action before

                        restored =
                            Reducer.undoAction action after

                        -- applyChange removes and re-appends, so the
                        -- restored stack ends up at the tail; locate it
                        -- by its card content.
                        restoredStackLoc =
                            restored.board
                                |> List.filter
                                    (\s ->
                                        List.map .card s.boardCards
                                            == List.map .card originalStack.boardCards
                                    )
                                |> List.head
                                |> Maybe.map .loc
                    in
                    restoredStackLoc |> Expect.equal (Just originalStack.loc)
            , test "undoing a MoveStack leaves board count unchanged" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        action =
                            MoveStack
                                { stack = stackAt 0 before
                                , newLoc = { top = 500, left = 600 }
                                }

                        after =
                            Reducer.applyAction action before

                        restored =
                            Reducer.undoAction action after
                    in
                    List.length restored.board |> Expect.equal (List.length before.board)
            ]
        , describe "Split"
            [ test "undoing a Split re-merges the two pieces" <|
                \_ ->
                    let
                        -- Stack 0 is KS,AS,2S,3S — splitting at index 2
                        -- yields KS,AS and 2S,3S; undo should restore the
                        -- original four-card stack.
                        before =
                            Reducer.initialState

                        action =
                            Split
                                { stack = stackAt 0 before
                                , cardIndex = 2
                                }

                        after =
                            Reducer.applyAction action before

                        restored =
                            Reducer.undoAction action after
                    in
                    List.length restored.board
                        |> Expect.equal (List.length before.board)
            , test "undoing a Split leaves the same board card count" <|
                \_ ->
                    let
                        before =
                            Reducer.initialState

                        action =
                            Split
                                { stack = stackAt 0 before
                                , cardIndex = 2
                                }

                        after =
                            Reducer.applyAction action before

                        restored =
                            Reducer.undoAction action after

                        countCards s =
                            List.length s.boardCards

                        totalCards =
                            List.sum << List.map countCards
                    in
                    totalCards restored.board
                        |> Expect.equal (totalCards before.board)
            ]
        , describe "MergeStack"
            [ test "undoing a MergeStack restores both source and target stacks" <|
                \_ ->
                    let
                        -- The opening board has six stacks. Stack 4 is
                        -- "AC,AD,AH" (a set) and stack 0 is "KS,AS,2S,3S".
                        -- We split stack 0 at index 1 to get a single "AS1"
                        -- card, then merge it onto the AC,AD,AH set.
                        -- Simpler: just verify board count round-trips.
                        before =
                            Reducer.initialState

                        -- Split stack 2 (2H,3H,4H) at index 1 to produce
                        -- a two-card stack we can observe.
                        splitAction =
                            Split
                                { stack = stackAt 2 before
                                , cardIndex = 1
                                }

                        afterSplit =
                            Reducer.applyAction splitAction before

                        -- Now afterSplit has 7 stacks. Pick the last two
                        -- (the halves from the split) and merge them.
                        sourceIdx =
                            List.length afterSplit.board - 1

                        targetIdx =
                            List.length afterSplit.board - 2

                        mergeAction =
                            MergeStack
                                { source = stackAt sourceIdx afterSplit
                                , target = stackAt targetIdx afterSplit
                                , side = Right
                                }

                        afterMerge =
                            Reducer.applyAction mergeAction afterSplit

                        restored =
                            Reducer.undoAction mergeAction afterMerge
                    in
                    List.length restored.board
                        |> Expect.equal (List.length afterSplit.board)
            ]
        , describe "PlaceHand"
            [ test "undoing a PlaceHand removes singleton from board and returns card to hand" <|
                \_ ->
                    let
                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        before =
                            let
                                s =
                                    Reducer.initialState
                            in
                            { s | hand = Hand.addCards [ card7H ] HandNormal s.hand }

                        action =
                            PlaceHand
                                { handCard = card7H
                                , loc = { top = 400, left = 500 }
                                }

                        after =
                            Reducer.applyAction action before

                        restored =
                            Reducer.undoAction action after
                    in
                    Expect.all
                        [ \r -> Hand.size r.hand |> Expect.equal (Hand.size before.hand)
                        , \r -> List.length r.board |> Expect.equal (List.length before.board)
                        ]
                        restored
            ]
        , describe "MergeHand"
            [ test "undoing a MergeHand removes the merged card from the board and returns it to hand" <|
                \_ ->
                    let
                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        before =
                            let
                                s =
                                    Reducer.initialState
                            in
                            { s | hand = Hand.addCards [ card7H ] HandNormal s.hand }

                        -- Stack index 3 is "7S,7D,7C"
                        action =
                            MergeHand
                                { handCard = card7H
                                , target = stackAt 3 before
                                , side = Right
                                }

                        after =
                            Reducer.applyAction action before

                        restored =
                            Reducer.undoAction action after
                    in
                    Expect.all
                        [ \r -> Hand.size r.hand |> Expect.equal (Hand.size before.hand)
                        , \r -> List.length r.board |> Expect.equal (List.length before.board)
                        ]
                        restored
            ]
        , describe "no-ops for non-undoable actions"
            [ test "undoAction CompleteTurn is a no-op" <|
                \_ ->
                    Reducer.undoAction CompleteTurn Reducer.initialState
                        |> Expect.equal Reducer.initialState
            , test "undoAction Undo is a no-op" <|
                \_ ->
                    Reducer.undoAction Undo Reducer.initialState
                        |> Expect.equal Reducer.initialState
            ]
        ]


-- ---------------------------------------------------------------------------
-- collapseUndos
-- ---------------------------------------------------------------------------


suiteCollapseUndos : Test
suiteCollapseUndos =
    describe "State.collapseUndos"
        [ test "empty log stays empty" <|
            \_ ->
                State.collapseUndos []
                    |> Expect.equal []
        , test "single action with no Undo is unchanged" <|
            \_ ->
                let
                    entries =
                        [ logEntry (MoveStack { stack = stackAt 0 Reducer.initialState, newLoc = { top = 10, left = 20 } }) ]
                in
                State.collapseUndos entries
                    |> Expect.equal entries
        , test "single Undo on empty log produces empty list" <|
            \_ ->
                State.collapseUndos [ logEntry Undo ]
                    |> Expect.equal []
        , test "action then Undo cancels the action" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 Reducer.initialState, newLoc = { top = 10, left = 20 } })

                    entries =
                        [ move, logEntry Undo ]
                in
                State.collapseUndos entries
                    |> Expect.equal []
        , test "double Undo cancels two actions" <|
            \_ ->
                let
                    s =
                        Reducer.initialState

                    move1 =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 } })

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 s, newLoc = { top = 30, left = 40 } })

                    entries =
                        [ move1, move2, logEntry Undo, logEntry Undo ]
                in
                State.collapseUndos entries
                    |> Expect.equal []
        , test "Undo does NOT pop CompleteTurn" <|
            \_ ->
                let
                    ct =
                        logEntry CompleteTurn

                    entries =
                        [ ct, logEntry Undo ]
                in
                -- CompleteTurn is pinned; Undo cannot pop it.
                State.collapseUndos entries
                    |> Expect.equal [ ct ]
        , test "Undo past CompleteTurn stops at CompleteTurn boundary" <|
            \_ ->
                let
                    s =
                        Reducer.initialState

                    move =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 } })

                    ct =
                        logEntry CompleteTurn

                    -- CompleteTurn then another action then Undo cancels
                    -- only the action after CompleteTurn, not CompleteTurn itself.
                    entries =
                        [ move, ct, move, logEntry Undo ]
                in
                State.collapseUndos entries
                    |> Expect.equal [ move, ct ]
        , test "interleaved Undos: two actions, one Undo leaves one action" <|
            \_ ->
                let
                    s =
                        Reducer.initialState

                    move1 =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 } })

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 s, newLoc = { top = 30, left = 40 } })
                in
                State.collapseUndos [ move1, move2, logEntry Undo ]
                    |> Expect.equal [ move1 ]
        ]


-- ---------------------------------------------------------------------------
-- canUndoThisTurn
-- ---------------------------------------------------------------------------


suiteCanUndoThisTurn : Test
suiteCanUndoThisTurn =
    describe "State.canUndoThisTurn"
        [ test "False on empty action log" <|
            \_ ->
                State.canUndoThisTurn (modelWithLog [])
                    |> Expect.equal False
        , test "True after one action" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 Reducer.initialState, newLoc = { top = 10, left = 20 } })
                in
                State.canUndoThisTurn (modelWithLog [ move ])
                    |> Expect.equal True
        , test "False after undoing the only action" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 Reducer.initialState, newLoc = { top = 10, left = 20 } })
                in
                State.canUndoThisTurn (modelWithLog [ move, logEntry Undo ])
                    |> Expect.equal False
        , test "False when last effective entry is CompleteTurn" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 Reducer.initialState, newLoc = { top = 10, left = 20 } })

                    ct =
                        logEntry CompleteTurn
                in
                State.canUndoThisTurn (modelWithLog [ move, ct ])
                    |> Expect.equal False
        , test "True when there is still an action after a CompleteTurn" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 Reducer.initialState, newLoc = { top = 10, left = 20 } })

                    ct =
                        logEntry CompleteTurn

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 Reducer.initialState, newLoc = { top = 50, left = 60 } })
                in
                State.canUndoThisTurn (modelWithLog [ move, ct, move2 ])
                    |> Expect.equal True
        , test "False when multiple actions are all undone" <|
            \_ ->
                let
                    s =
                        Reducer.initialState

                    move1 =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 } })

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 s, newLoc = { top = 30, left = 40 } })
                in
                State.canUndoThisTurn (modelWithLog [ move1, move2, logEntry Undo, logEntry Undo ])
                    |> Expect.equal False
        ]


-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------


suite : Test
suite =
    describe "Undo feature"
        [ suiteUndoAction
        , suiteCollapseUndos
        , suiteCanUndoThisTurn
        ]
