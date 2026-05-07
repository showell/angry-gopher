module Game.Reducer exposing
    ( State
    , applyAction
    , initialState
    , undoAction
    )

{-| Pure action reducer: take a `GameEvent` and apply it to a
`(board, hand)` state to produce the next state. Shared by both
live-play action application and replay. Live-play callers wrap
this with Model-level concerns (Score, cardsPlayedThisTurn) in
`Main.Apply`; the replay walker calls it directly.

No-op for `CompleteTurn` and `Undo` — turn-logic isn't
modeled here (and Undo is deliberately deferred in V1 replay).

-}

import Game.BoardActions as BoardActions
import Game.CardStack as CardStack exposing (CardStack, isStacksEqual)
import Game.Dealer
import Game.Execute as Execute
import Game.Hand as Hand exposing (Hand)
import Game.GameEvent exposing (GameEvent(..))


type alias State =
    { board : List CardStack
    , hand : Hand
    }


initialState : State
initialState =
    { board = Game.Dealer.initialBoard
    , hand = Hand.empty
    }


applyAction : GameEvent -> State -> State
applyAction action state =
    case action of
        Split { stack, cardIndex } ->
            { state | board = Execute.split stack cardIndex state.board }

        MergeStack { source, target, side } ->
            { state | board = Execute.mergeStack source target side state.board }

        MergeHand { handCard, target, side } ->
            Execute.mergeHand handCard target side state.board state.hand

        PlaceHand { handCard, loc } ->
            Execute.placeHand handCard loc state.board state.hand

        MoveStack { stack, newLoc } ->
            { state | board = Execute.moveStack stack newLoc state.board }

        CompleteTurn ->
            state

        Undo ->
            state


{-| Reverse a GameEvent on (board, hand) — the undo primitive.
Each action carries its pre-action stacks in the payload, so the
post-action stacks are fully derivable: MoveStack's destination
is newLoc, Split's pieces are CardStack.split, Merge's result is
tryStackMerge/tryHandMerge. Swapping remove/add restores the
pre-action board; handCardsToRelease cards return to hand.

CompleteTurn and Undo are no-ops here; callers guard against them.
-}
undoAction : GameEvent -> State -> State
undoAction action state =
    case action of
        MoveStack { stack, newLoc } ->
            let
                change =
                    { stacksToRemove = [ { stack | loc = newLoc } ]
                    , stacksToAdd = [ stack ]
                    , handCardsToRelease = []
                    }
            in
            { state | board = applyChange change state.board }

        Split { stack, cardIndex } ->
            let
                change =
                    { stacksToRemove = CardStack.split cardIndex stack
                    , stacksToAdd = [ stack ]
                    , handCardsToRelease = []
                    }
            in
            { state | board = applyChange change state.board }

        MergeStack { source, target, side } ->
            case BoardActions.tryStackMerge target source side of
                Just mergeChange ->
                    case mergeChange.stacksToAdd of
                        [ merged ] ->
                            let
                                change =
                                    { stacksToRemove = [ merged ]
                                    , stacksToAdd = [ target, source ]
                                    , handCardsToRelease = []
                                    }
                            in
                            { state | board = applyChange change state.board }

                        _ ->
                            state

                Nothing ->
                    state

        MergeHand { handCard, target, side } ->
            let
                hc =
                    { card = handCard, state = CardStack.HandNormal }
            in
            case BoardActions.tryHandMerge target hc side of
                Just mergeChange ->
                    case mergeChange.stacksToAdd of
                        [ merged ] ->
                            let
                                change =
                                    { stacksToRemove = [ merged ]
                                    , stacksToAdd = [ target ]
                                    , handCardsToRelease = []
                                    }
                            in
                            { board = applyChange change state.board
                            , hand = Hand.addHandCards [ hc ] state.hand
                            }

                        _ ->
                            state

                Nothing ->
                    state

        PlaceHand { handCard, loc } ->
            let
                hc =
                    { card = handCard, state = CardStack.HandNormal }

                change =
                    { stacksToRemove = [ CardStack.fromHandCard hc loc ]
                    , stacksToAdd = []
                    , handCardsToRelease = []
                    }
            in
            { board = applyChange change state.board
            , hand = Hand.addHandCards [ hc ] state.hand
            }

        CompleteTurn ->
            state

        Undo ->
            state



-- HELPERS


applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter (\s -> not (List.any (isStacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd


