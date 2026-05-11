module Game.Execute exposing (mergeHand, mergeStack, moveStack, placeHand, split, undoEvent)

{-| Honest board mutators, one per `GameEvent` variant. Each
function takes the board (and whatever per-action data it
needs) and returns the new board — no `Maybe`s in the
signature.

If the caller passes a stack that isn't on the board, that's
a bridge bug; the function logs it loudly via `Debug.log`
and returns the board unchanged. The log is the
surfacer; without it (or with silent identity-return) the
divergence cascades downstream and gets harder to trace.

-}

import Game.BoardActions as BoardActions exposing (Side)
import Game.CardStack as CardStack exposing (BoardLocation, CardStack, findStack, isStacksEqual)
import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent(..))
import Game.Hand as Hand exposing (Hand)
import Game.Rules.Card exposing (Card)


{-| Reverse a `GameEvent` against a `GameState`. Each variant
carries its pre-action stacks in the payload, so the post-
action shape is fully derivable: swapping `stacksToRemove`
and `stacksToAdd` undoes the mutation. Hand actions also
return the released card to the active hand and decrement
`cardsPlayedThisTurn`. `CompleteTurn` and `Undo` are no-ops.
-}
undoEvent : GameEvent -> GameState -> GameState
undoEvent event state =
    case event of
        MoveStack { stack, newLoc } ->
            let
                change =
                    { stacksToRemove = [ { stack | loc = newLoc } ]
                    , stacksToAdd = [ stack ]
                    , handCardsToRelease = []
                    }
            in
            { state | board = applyBoardChange change state.board }

        Split { stack, cardIndex } ->
            let
                change =
                    { stacksToRemove = CardStack.split cardIndex stack
                    , stacksToAdd = [ stack ]
                    , handCardsToRelease = []
                    }
            in
            { state | board = applyBoardChange change state.board }

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
                            { state | board = applyBoardChange change state.board }

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

                                newHand =
                                    Hand.addHandCards [ hc ] (Hand.activeHand state)
                            in
                            Hand.setActiveHand newHand
                                { state
                                    | board = applyBoardChange change state.board
                                    , cardsPlayedThisTurn = state.cardsPlayedThisTurn - 1
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

                newHand =
                    Hand.addHandCards [ hc ] (Hand.activeHand state)
            in
            Hand.setActiveHand newHand
                { state
                    | board = applyBoardChange change state.board
                    , cardsPlayedThisTurn = state.cardsPlayedThisTurn - 1
                }

        CompleteTurn ->
            state

        Undo ->
            state


{-| Split the given stack at `cardIndex`, returning a new
board with the original stack removed and its two split
pieces appended. Bridge-bug case: stack not on board → log
+ board unchanged.
-}
split : CardStack -> Int -> List CardStack -> List CardStack
split stack cardIndex board =
    case findStack stack board of
        Just real ->
            List.filter (not << isStacksEqual real) board
                ++ CardStack.split cardIndex real

        Nothing ->
            let
                _ =
                    Debug.log "[Execute.split] stack not on board — skipping (bridge bug)" stack
            in
            board


{-| Move the given stack to `newLoc`, returning a new board
with the original stack removed and the relocated stack
appended. Bridge-bug case: stack not on board → log + board
unchanged.
-}
moveStack : CardStack -> BoardLocation -> List CardStack -> List CardStack
moveStack stack newLoc board =
    case findStack stack board of
        Just real ->
            List.filter (not << isStacksEqual real) board
                ++ [ { real | loc = newLoc } ]

        Nothing ->
            let
                _ =
                    Debug.log "[Execute.moveStack] stack not on board — skipping (bridge bug)" stack
            in
            board


{-| Merge `source` onto `target` from the given side, returning
a new board with both originals removed and the merged stack
appended. Three failure cases: source not on board (bridge
bug), target not on board (bridge bug), tryStackMerge rejects
the geometry (rules bug). Each logs and returns the board
unchanged.
-}
mergeStack : CardStack -> CardStack -> Side -> List CardStack -> List CardStack
mergeStack source target side board =
    case ( findStack source board, findStack target board ) of
        ( Just realSource, Just realTarget ) ->
            case BoardActions.tryStackMerge realTarget realSource side of
                Just change ->
                    applyBoardChange change board

                Nothing ->
                    let
                        _ =
                            Debug.log "[Execute.mergeStack] tryStackMerge rejected — skipping (rules bug?)"
                                { source = source, target = target, side = side }
                    in
                    board

        ( Nothing, _ ) ->
            let
                _ =
                    Debug.log "[Execute.mergeStack] source stack not on board — skipping (bridge bug)" source
            in
            board

        ( _, Nothing ) ->
            let
                _ =
                    Debug.log "[Execute.mergeStack] target stack not on board — skipping (bridge bug)" target
            in
            board


{-| Merge `handCard` onto `target` from the given side. Returns
the new (board, hand) — board has the merged stack, hand has
the merged card removed. Failure cases (target missing, hand
card missing, tryHandMerge rejects) log and return board+hand
unchanged.
-}
mergeHand :
    Card
    -> CardStack
    -> Side
    -> List CardStack
    -> Hand
    -> { board : List CardStack, hand : Hand }
mergeHand handCardId target side board hand =
    case ( findStack target board, Hand.findHandCard handCardId hand ) of
        ( Just realTarget, Just hc ) ->
            case BoardActions.tryHandMerge realTarget hc side of
                Just change ->
                    { board = applyBoardChange change board
                    , hand = Hand.removeHandCard hc hand
                    }

                Nothing ->
                    let
                        _ =
                            Debug.log "[Execute.mergeHand] tryHandMerge rejected — skipping (rules bug?)"
                                { handCard = handCardId, target = target, side = side }
                    in
                    { board = board, hand = hand }

        ( Nothing, _ ) ->
            let
                _ =
                    Debug.log "[Execute.mergeHand] target stack not on board — skipping (bridge bug)" target
            in
            { board = board, hand = hand }

        ( _, Nothing ) ->
            let
                _ =
                    Debug.log
                        ("[Execute.mergeHand] hand_card not in active hand — skipping. "
                            ++ "Bridge-bug surfacer: agent transcript referenced a card "
                            ++ "the eager applier doesn't have in hand."
                        )
                        { handCard = handCardId, handSize = List.length hand.handCards }
            in
            { board = board, hand = hand }


{-| Place `handCard` on the board at `loc`. Returns the new
(board, hand) — board has the new singleton stack, hand has
the placed card removed. Bridge-bug case: hand card not in
active hand → log + board+hand unchanged.
-}
placeHand :
    Card
    -> BoardLocation
    -> List CardStack
    -> Hand
    -> { board : List CardStack, hand : Hand }
placeHand handCardId loc board hand =
    case Hand.findHandCard handCardId hand of
        Just hc ->
            { board = applyBoardChange (BoardActions.placeHandCardAt hc loc) board
            , hand = Hand.removeHandCard hc hand
            }

        Nothing ->
            let
                _ =
                    Debug.log
                        ("[Execute.placeHand] hand_card not in active hand — skipping. "
                            ++ "Bridge-bug surfacer: agent transcript referenced a card "
                            ++ "the eager applier doesn't have in hand."
                        )
                        { handCard = handCardId, handSize = List.length hand.handCards }
            in
            { board = board, hand = hand }



-- HELPERS


applyBoardChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyBoardChange change board =
    List.filter (\s -> not (List.any (isStacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd
