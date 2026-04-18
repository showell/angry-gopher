module LynRummy.Replay exposing
    ( State
    , applyAction
    , initialState
    )

{-| Pure replay primitives: take a `WireAction` and apply it to
a `(board, hand)` state to produce the next state. This is the
function the UI replay walker calls on each step.

No-op for `Draw`, `Discard`, `CompleteTurn`, `Undo` — turn-logic
isn't modeled yet. When it is, they'll get their own transitions
here.

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
            case ( listAt targetStack state.board, findHandCard handCard state.hand ) of
                ( Just target, Just hc ) ->
                    case BoardActions.tryHandMerge target hc side of
                        Just change ->
                            { state
                                | board = applyChange change state.board
                                , hand = Hand.removeHandCard hc state.hand
                            }

                        Nothing ->
                            state

                _ ->
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

        Draw ->
            state

        Discard _ ->
            state

        CompleteTurn ->
            state

        Undo ->
            state



-- HELPERS (local; duplicated across Main.elm and here. ~6 LOC
-- total; cheaper than coupling the modules for now.)


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
