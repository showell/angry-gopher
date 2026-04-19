module LynRummy.Replay exposing
    ( State
    , applyAction
    , initialState
    )

{-| Pure replay primitives: take a `WireAction` and apply it to
a `(board, hand)` state to produce the next state. This is the
function the UI replay walker calls on each step.

No-op for `CompleteTurn`, `Undo`, `PlayTrick` — turn-logic isn't
modeled here (and Undo is deliberately deferred in V1 replay).

-}

import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.Card exposing (Card)
import LynRummy.CardStack as CardStack exposing (CardStack, HandCard, stacksEqual)
import LynRummy.Dealer
import LynRummy.GestureArbitration as GA
import LynRummy.Hand as Hand exposing (Hand)
import LynRummy.WireAction exposing (WireAction(..))


type alias State =
    { board : List CardStack
    , hand : Hand
    }


initialState : State
initialState =
    { board = LynRummy.Dealer.initialBoard
    , hand = LynRummy.Dealer.openingHand
    }


applyAction : WireAction -> State -> State
applyAction action state =
    case action of
        Split { stackIndex, cardIndex } ->
            { state | board = GA.applySplit stackIndex cardIndex state.board }

        MergeStack { sourceStack, targetStack, side } ->
            case ( listAt sourceStack state.board, listAt targetStack state.board ) of
                ( Just source, Just target ) ->
                    case BoardActions.tryStackMerge target source side of
                        Just change ->
                            { state | board = applyChange change state.board }

                        Nothing ->
                            state

                _ ->
                    state

        MergeHand { handCard, targetStack, side } ->
            case listAt targetStack state.board of
                Just target ->
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
                    case BoardActions.tryHandMerge target hc side of
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
                            BoardActions.placeHandCard hc loc
                    in
                    { state
                        | board = applyChange change state.board
                        , hand = Hand.removeHandCard hc state.hand
                    }

                Nothing ->
                    state

        MoveStack { stackIndex, newLoc } ->
            case listAt stackIndex state.board of
                Just stack ->
                    let
                        change =
                            BoardActions.moveStack stack newLoc
                    in
                    { state | board = applyChange change state.board }

                Nothing ->
                    state

        CompleteTurn ->
            state

        Undo ->
            state

        PlayTrick _ ->
            -- Submission-time convenience; the server expands
            -- PlayTrick to TrickResult at receipt time and persists
            -- the latter. A PlayTrick should never end up in a
            -- replayed log; if one does, no-op.
            state

        TrickResult p ->
            let
                boardSansRemoved =
                    List.foldl removeStackOnce state.board p.stacksToRemove

                newBoard =
                    boardSansRemoved ++ p.stacksToAdd

                newHand =
                    List.foldl removeHandCardByContent state.hand p.handCardsReleased
            in
            { state | board = newBoard, hand = newHand }



-- HELPERS (local; duplicated across Main.elm and here. ~6 LOC
-- total; cheaper than coupling the modules for now.)


removeStackOnce : CardStack -> List CardStack -> List CardStack
removeStackOnce target board =
    List.filter (\s -> not (stacksEqual s target)) board


removeHandCardByContent : Card -> Hand -> Hand
removeHandCardByContent card hand =
    case findHandCard card hand of
        Just hc ->
            Hand.removeHandCard hc hand

        Nothing ->
            hand


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)


applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter (\s -> not (List.any (stacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd


{-| Find a hand card by content identity (ignores state). The
wire's `Card` references identify a hand card; the actual
`HandCard` record on the board carries the mutable state that
matters for rendering.
-}
findHandCard : Card -> Hand -> Maybe HandCard
findHandCard card hand =
    hand.handCards
        |> List.filter (\hc -> CardStack.handCardSameCard hc { card = card, state = CardStack.HandNormal })
        |> List.head
