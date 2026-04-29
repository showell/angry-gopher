module Game.Reducer exposing
    ( State
    , applyAction
    , initialState
    )

{-| Pure action reducer: take a `WireAction` and apply it to a
`(board, hand)` state to produce the next state. Shared by both
live-play action application and replay. Live-play callers wrap
this with Model-level concerns (Score, cardsPlayedThisTurn) in
`Main.Apply`; the replay walker calls it directly.

No-op for `CompleteTurn` and `Undo` — turn-logic isn't
modeled here (and Undo is deliberately deferred in V1 replay).

-}

import Game.BoardActions as BoardActions
import Game.Rules.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack, HandCard, findStack, isStacksEqual)
import Game.Dealer
import Game.Hand as Hand exposing (Hand)
import Game.WireAction exposing (WireAction(..))


type alias State =
    { board : List CardStack
    , hand : Hand
    }


initialState : State
initialState =
    { board = Game.Dealer.initialBoard
    , hand = Hand.empty
    }


applyAction : WireAction -> State -> State
applyAction action state =
    case action of
        Split { stack, cardIndex } ->
            case findStack stack state.board of
                Just real ->
                    { state
                        | board =
                            List.filter (not << isStacksEqual real) state.board
                                ++ CardStack.split cardIndex real
                    }

                Nothing ->
                    state

        MergeStack { source, target, side } ->
            case ( findStack source state.board, findStack target state.board ) of
                ( Just realSource, Just realTarget ) ->
                    case BoardActions.tryStackMerge realTarget realSource side of
                        Just change ->
                            { state | board = applyChange change state.board }

                        Nothing ->
                            state

                _ ->
                    state

        MergeHand { handCard, target, side } ->
            case findStack target state.board of
                Just realTarget ->
                    let
                        -- When the card isn't in the tracked hand — a
                        -- replay of the opponent's turn whose hand was
                        -- server-dealt and never sent client-side —
                        -- fall back to a synthetic HandCard so the
                        -- board still advances. Skip the hand-update
                        -- step in that case (we aren't tracking that
                        -- player's hand anyway).
                        ( hc, mutateHand ) =
                            case findHandCard handCard state.hand of
                                Just real ->
                                    ( real, True )

                                Nothing ->
                                    ( { card = handCard, state = CardStack.HandNormal }, False )
                    in
                    case BoardActions.tryHandMerge realTarget hc side of
                        Just change ->
                            { state
                                | board = applyChange change state.board
                                , hand =
                                    if mutateHand then
                                        Hand.removeHandCard hc state.hand

                                    else
                                        state.hand
                            }

                        Nothing ->
                            state

                Nothing ->
                    state

        PlaceHand { handCard, loc } ->
            case findHandCard handCard state.hand of
                Just hc ->
                    let
                        change =
                            BoardActions.placeHandCardAt hc loc
                    in
                    { state
                        | board = applyChange change state.board
                        , hand = Hand.removeHandCard hc state.hand
                    }

                Nothing ->
                    state

        MoveStack { stack, newLoc } ->
            case findStack stack state.board of
                Just real ->
                    let
                        change =
                            BoardActions.moveStackTo real newLoc
                    in
                    { state | board = applyChange change state.board }

                Nothing ->
                    state

        CompleteTurn ->
            state

        Undo ->
            state



-- HELPERS


applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter (\s -> not (List.any (isStacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd


{-| Find a hand card by content identity (ignores state). The
wire's `Card` references identify a hand card; the actual
`HandCard` record on the board carries the mutable state that
matters for rendering.
-}
findHandCard : Card -> Hand -> Maybe HandCard
findHandCard card hand =
    hand.handCards
        |> List.filter (\hc -> CardStack.isHandCardSameCard hc { card = card, state = CardStack.HandNormal })
        |> List.head
