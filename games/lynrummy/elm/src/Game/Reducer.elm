module Game.Reducer exposing
    ( State
    , applyAction
    , initialState
    , undoAction
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
                    let
                        _ =
                            Debug.log "[Reducer.Split] target stack not on board — skipping (bridge bug)" stack
                    in
                    state

        MergeStack { source, target, side } ->
            case ( findStack source state.board, findStack target state.board ) of
                ( Just realSource, Just realTarget ) ->
                    case BoardActions.tryStackMerge realTarget realSource side of
                        Just change ->
                            { state | board = applyChange change state.board }

                        Nothing ->
                            let
                                _ =
                                    Debug.log "[Reducer.MergeStack] tryStackMerge rejected — skipping (rules bug?)" { source = source, target = target, side = side }
                            in
                            state

                ( Nothing, _ ) ->
                    let
                        _ =
                            Debug.log "[Reducer.MergeStack] source stack not on board — skipping (bridge bug)" source
                    in
                    state

                ( _, Nothing ) ->
                    let
                        _ =
                            Debug.log "[Reducer.MergeStack] target stack not on board — skipping (bridge bug)" target
                    in
                    state

        MergeHand { handCard, target, side } ->
            case findStack target state.board of
                Just realTarget ->
                    case findHandCard handCard state.hand of
                        Just hc ->
                            case BoardActions.tryHandMerge realTarget hc side of
                                Just change ->
                                    { state
                                        | board = applyChange change state.board
                                        , hand = Hand.removeHandCard hc state.hand
                                    }

                                Nothing ->
                                    let
                                        _ =
                                            Debug.log "[Reducer.MergeHand] tryHandMerge rejected — skipping (rules bug?)" { handCard = handCard, target = target, side = side }
                                    in
                                    state

                        Nothing ->
                            -- The card the agent transcript wants to
                            -- merge isn't in this player's tracked
                            -- hand. Per
                            -- memory/feedback_dont_paper_over_problems.md:
                            -- this WAS a silent fallback (synthetic
                            -- HandCard, board advances anyway) — that's
                            -- exactly how seed-44's "9D appears
                            -- spontaneously" hid. Now we log loud and
                            -- skip the action; the visible state stays
                            -- as-is, the cascade is annotated.
                            let
                                _ =
                                    Debug.log
                                        ("[Reducer.MergeHand] hand_card not in active hand — skipping. "
                                            ++ "This is the bridge-bug surfacer: agent transcript referenced a card "
                                            ++ "the eager applier doesn't have in hand. Likely a missed CompleteTurn "
                                            ++ "or wrong active_player_index."
                                        )
                                        { handCard = handCard, handSize = List.length state.hand.handCards }
                            in
                            state

                Nothing ->
                    let
                        _ =
                            Debug.log "[Reducer.MergeHand] target stack not on board — skipping (bridge bug)" target
                    in
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
                    let
                        _ =
                            Debug.log
                                ("[Reducer.PlaceHand] hand_card not in active hand — skipping. "
                                    ++ "Agent transcript references a card not in the eager applier's view. "
                                    ++ "Likely a missed CompleteTurn or wrong active_player_index."
                                )
                                { handCard = handCard, handSize = List.length state.hand.handCards }
                    in
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
                    let
                        _ =
                            Debug.log "[Reducer.MoveStack] target stack not on board — skipping (bridge bug)" stack
                    in
                    state

        CompleteTurn ->
            state

        Undo ->
            state


{-| Reverse a WireAction on (board, hand) — the undo primitive.
Each action carries its pre-action stacks in the payload, so the
post-action stacks are fully derivable: MoveStack's destination
is newLoc, Split's pieces are CardStack.split, Merge's result is
tryStackMerge/tryHandMerge. Swapping remove/add restores the
pre-action board; handCardsToRelease cards return to hand.

CompleteTurn and Undo are no-ops here; callers guard against them.
-}
undoAction : WireAction -> State -> State
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
