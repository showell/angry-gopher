module Game.UndoTest exposing (suite)

{-| Tests for the Undo feature.

Covers:
  - `Game.Execute.undoEvent` — round-trip for all five primitives:
    Split, MergeStack, MergeHand, PlaceHand, MoveStack.
  - `Main.ActionLog.collapseUndos` — token collapsing in the action log.
  - `Main.State.canUndoThisTurn` — button-enable predicate.

Strategy: for `undoEvent`, apply an action with `applyEvent` then
immediately `undoEvent` on the result and assert the relevant
post-undo invariants. This sidesteps fragile board-construction
and directly verifies the round-trip.
-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.CardStack exposing (CardStack, HandCardState(..))
import Game.Dealer
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent(..))
import Game.Hand as Hand
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Game.ActionLog as ActionLog exposing (ActionLogEntry)
import Main.State as State
import Test exposing (Test, describe, test)



-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------


{-| Return the CardStack at position `idx` in state.board. -}
stackAt : Int -> GameState -> CardStack
stackAt idx state =
    state.board
        |> List.drop idx
        |> List.head
        |> Maybe.withDefault
            { boardCards = [], loc = { top = 0, left = 0 } }


{-| Construct a minimal ActionLogEntry for a GameEvent. -}
logEntry : GameEvent -> ActionLogEntry
logEntry action =
    { action = action }


initialGameState : GameState
initialGameState =
    { board = Game.Dealer.initialBoard
    , hands = [ Hand.empty, Hand.empty ]
    , activePlayerIndex = 0
    , turnIndex = 0
    , deck = []
    , cardsPlayedThisTurn = 0
    , victorAwarded = False
    }



-- ---------------------------------------------------------------------------
-- undoEvent: round-trip tests
-- ---------------------------------------------------------------------------


suiteUndoEvent : Test
suiteUndoEvent =
    describe "Execute.undoEvent — round-trip invariant"
        [ describe "MoveStack"
            [ test "undoing a MoveStack restores the original location of the moved stack" <|
                \_ ->
                    let
                        before =
                            initialGameState

                        originalStack =
                            stackAt 0 before

                        action =
                            MoveStack
                                { stack = originalStack
                                , newLoc = { top = 500, left = 600 }
                                , boardPath = []
                                }

                        after =
                            State.applyEvent action before

                        restored =
                            Execute.undoEvent action after

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
                            initialGameState

                        action =
                            MoveStack
                                { stack = stackAt 0 before
                                , newLoc = { top = 500, left = 600 }
                                , boardPath = []
                                }

                        after =
                            State.applyEvent action before

                        restored =
                            Execute.undoEvent action after
                    in
                    List.length restored.board |> Expect.equal (List.length before.board)
            ]
        , describe "Split"
            [ test "undoing a Split re-merges the two pieces" <|
                \_ ->
                    let
                        before =
                            initialGameState

                        action =
                            Split
                                { stack = stackAt 0 before
                                , cardIndex = 2
                                }

                        after =
                            State.applyEvent action before

                        restored =
                            Execute.undoEvent action after
                    in
                    List.length restored.board
                        |> Expect.equal (List.length before.board)
            , test "undoing a Split leaves the same board card count" <|
                \_ ->
                    let
                        before =
                            initialGameState

                        action =
                            Split
                                { stack = stackAt 0 before
                                , cardIndex = 2
                                }

                        after =
                            State.applyEvent action before

                        restored =
                            Execute.undoEvent action after

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
                        before =
                            initialGameState

                        splitAction =
                            Split
                                { stack = stackAt 2 before
                                , cardIndex = 1
                                }

                        afterSplit =
                            State.applyEvent splitAction before

                        sourceIdx =
                            List.length afterSplit.board - 1

                        targetIdx =
                            List.length afterSplit.board - 2

                        mergeAction =
                            MergeStack
                                { source = stackAt sourceIdx afterSplit
                                , target = stackAt targetIdx afterSplit
                                , side = Right
                                , boardPath = []
                                }

                        afterMerge =
                            State.applyEvent mergeAction afterSplit

                        restored =
                            Execute.undoEvent mergeAction afterMerge
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

                        beforeHand =
                            Hand.addCards [ card7H ] HandNormal Hand.empty

                        before =
                            { initialGameState | hands = [ beforeHand, Hand.empty ] }

                        action =
                            PlaceHand
                                { handCard = card7H
                                , loc = { top = 400, left = 500 }
                                }

                        after =
                            State.applyEvent action before

                        restored =
                            Execute.undoEvent action after
                    in
                    Expect.all
                        [ \r -> Hand.size (Hand.activeHand r) |> Expect.equal (Hand.size beforeHand)
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

                        beforeHand =
                            Hand.addCards [ card7H ] HandNormal Hand.empty

                        before =
                            { initialGameState | hands = [ beforeHand, Hand.empty ] }

                        -- Stack index 3 is "7S,7D,7C"
                        action =
                            MergeHand
                                { handCard = card7H
                                , target = stackAt 3 before
                                , side = Right
                                }

                        after =
                            State.applyEvent action before

                        restored =
                            Execute.undoEvent action after
                    in
                    Expect.all
                        [ \r -> Hand.size (Hand.activeHand r) |> Expect.equal (Hand.size beforeHand)
                        , \r -> List.length r.board |> Expect.equal (List.length before.board)
                        ]
                        restored
            ]
        , describe "no-ops for non-undoable actions"
            [ test "undoEvent CompleteTurn is a no-op" <|
                \_ ->
                    Execute.undoEvent CompleteTurn initialGameState
                        |> Expect.equal initialGameState
            , test "undoEvent Undo is a no-op" <|
                \_ ->
                    Execute.undoEvent Undo initialGameState
                        |> Expect.equal initialGameState
            ]
        ]



-- ---------------------------------------------------------------------------
-- collapseUndos
-- ---------------------------------------------------------------------------


suiteCollapseUndos : Test
suiteCollapseUndos =
    describe "ActionLog.collapseUndos"
        [ test "empty log stays empty" <|
            \_ ->
                ActionLog.collapseUndos []
                    |> Expect.equal []
        , test "single action with no Undo is unchanged" <|
            \_ ->
                let
                    entries =
                        [ logEntry (MoveStack { stack = stackAt 0 initialGameState, newLoc = { top = 10, left = 20 }, boardPath = [] }) ]
                in
                ActionLog.collapseUndos entries
                    |> Expect.equal entries
        , test "action then Undo cancels the action" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 initialGameState, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    entries =
                        [ move, logEntry Undo ]
                in
                ActionLog.collapseUndos entries
                    |> Expect.equal []
        , test "double Undo cancels two actions" <|
            \_ ->
                let
                    s =
                        initialGameState

                    move1 =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 s, newLoc = { top = 30, left = 40 }, boardPath = [] })

                    entries =
                        [ move1, move2, logEntry Undo, logEntry Undo ]
                in
                ActionLog.collapseUndos entries
                    |> Expect.equal []
        , test "Undo cancels a CompleteTurn like any other action" <|
            \_ ->
                let
                    ct =
                        logEntry CompleteTurn

                    entries =
                        [ ct, logEntry Undo ]
                in
                ActionLog.collapseUndos entries
                    |> Expect.equal []
        , test "single Undo cancels only the most recent action" <|
            \_ ->
                let
                    s =
                        initialGameState

                    move =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    ct =
                        logEntry CompleteTurn

                    entries =
                        [ move, ct, move, logEntry Undo ]
                in
                ActionLog.collapseUndos entries
                    |> Expect.equal [ move, ct ]
        , test "interleaved Undos: two actions, one Undo leaves one action" <|
            \_ ->
                let
                    s =
                        initialGameState

                    move1 =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 s, newLoc = { top = 30, left = 40 }, boardPath = [] })
                in
                ActionLog.collapseUndos [ move1, move2, logEntry Undo ]
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
                State.canUndoThisTurn []
                    |> Expect.equal False
        , test "True after one action" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 initialGameState, newLoc = { top = 10, left = 20 }, boardPath = [] })
                in
                State.canUndoThisTurn [ move ]
                    |> Expect.equal True
        , test "False after undoing the only action" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 initialGameState, newLoc = { top = 10, left = 20 }, boardPath = [] })
                in
                State.canUndoThisTurn [ move, logEntry Undo ]
                    |> Expect.equal False
        , test "False when last effective entry is CompleteTurn" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 initialGameState, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    ct =
                        logEntry CompleteTurn
                in
                State.canUndoThisTurn [ move, ct ]
                    |> Expect.equal False
        , test "True when there is still an action after a CompleteTurn" <|
            \_ ->
                let
                    move =
                        logEntry (MoveStack { stack = stackAt 0 initialGameState, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    ct =
                        logEntry CompleteTurn

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 initialGameState, newLoc = { top = 50, left = 60 }, boardPath = [] })
                in
                State.canUndoThisTurn [ move, ct, move2 ]
                    |> Expect.equal True
        , test "False when multiple actions are all undone" <|
            \_ ->
                let
                    s =
                        initialGameState

                    move1 =
                        logEntry (MoveStack { stack = stackAt 0 s, newLoc = { top = 10, left = 20 }, boardPath = [] })

                    move2 =
                        logEntry (MoveStack { stack = stackAt 1 s, newLoc = { top = 30, left = 40 }, boardPath = [] })
                in
                State.canUndoThisTurn [ move1, move2, logEntry Undo, logEntry Undo ]
                    |> Expect.equal False
        ]



-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------


suite : Test
suite =
    describe "Undo feature"
        [ suiteUndoEvent
        , suiteCollapseUndos
        , suiteCanUndoThisTurn
        ]
