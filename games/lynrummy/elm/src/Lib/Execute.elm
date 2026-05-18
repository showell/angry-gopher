module Lib.Execute exposing
    ( mergeHand
    , mergeStack
    , moveStack
    , placeHand
    , split
    , undoEvent
    , undoMergeStack
    , undoMoveStack
    , undoSplit
    )

{-| Honest mutators for the game's primitive actions.

Board-only verbs (`split`, `mergeStack`, `moveStack`) take and
return a board; each has a matching `undoX` that reverses it
the same way (board-only, O(1)-per-undo). Hand verbs
(`mergeHand`, `placeHand`) take and return a full `GameState`
because the action must update board + active hand +
`cardsPlayedThisTurn` atomically — a card can only be in one
place at a time, so the post-call state has to be the
consistent one (not an intermediate `{ board, hand }` the
caller would need to splice back).

`undoEvent` is the GameState-level dispatcher: it routes board
verbs to the board-level undo helpers and handles the hand
verbs inline. Direct callers that only need a board (e.g.
the puzzle host) can skip `undoEvent` and call
`undoSplit`/`undoMoveStack`/`undoMergeStack` directly.

Bridge-bug failures (referenced card or stack not present) log
via `Debug.log` and return the input unchanged. The log is the
surfacer; without it (or with silent identity-return) the
divergence cascades downstream and gets harder to trace.

-}

import Lib.BoardActions as BoardActions exposing (Side)
import Lib.CardStack as CardStack exposing (BoardLocation, CardStack, findStack, isStacksEqual)
import Lib.GameState exposing (GameState)
import Lib.GameEvent exposing (GameEvent(..))
import Lib.Hand as Hand
import Lib.Rules.Card exposing (Card)


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
            { state | board = undoMoveStack stack newLoc state.board }

        Split { stack, cardIndex } ->
            { state | board = undoSplit stack cardIndex state.board }

        MergeStack { source, target, side } ->
            { state | board = undoMergeStack source target side state.board }

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


{-| Reverse a prior `split` of the same stack at the same
cardIndex: remove the two split pieces from the board and put
the original back. O(1)-per-undo (no board-replay needed).
-}
undoSplit : CardStack -> Int -> List CardStack -> List CardStack
undoSplit stack cardIndex board =
    let
        change =
            { stacksToRemove = CardStack.split cardIndex stack
            , stacksToAdd = [ stack ]
            , handCardsToRelease = []
            }
    in
    applyBoardChange change board


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


{-| Reverse a prior `moveStack` of the same stack to the same
newLoc: remove the relocated stack and put the original loc
copy back. O(1)-per-undo.
-}
undoMoveStack : CardStack -> BoardLocation -> List CardStack -> List CardStack
undoMoveStack stack newLoc board =
    let
        change =
            { stacksToRemove = [ { stack | loc = newLoc } ]
            , stacksToAdd = [ stack ]
            , handCardsToRelease = []
            }
    in
    applyBoardChange change board


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


{-| Reverse a prior `mergeStack` of `source` onto `target` from
`side`: remove the merged stack and put `target` and `source`
back as separate stacks. O(1)-per-undo.

Re-derives the merged stack by re-running `BoardActions.tryStackMerge`
on the same inputs — keeps this helper self-contained (no need
to thread the merged stack through the caller). Falls back to
the original board on a bridge bug (tryStackMerge changes its
mind or surfaces multiple stacksToAdd).
-}
undoMergeStack : CardStack -> CardStack -> Side -> List CardStack -> List CardStack
undoMergeStack source target side board =
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
                    applyBoardChange change board

                _ ->
                    board

        Nothing ->
            board


{-| Merge `handCard` onto `target` from the given side. Atomically
moves the card from the active hand onto the board and bumps
`cardsPlayedThisTurn`. Failure cases (target missing, hand card
missing, `tryHandMerge` rejects) log and return state unchanged.
-}
mergeHand : Card -> CardStack -> Side -> GameState -> GameState
mergeHand handCardId target side state =
    let
        hand =
            Hand.activeHand state
    in
    case ( findStack target state.board, Hand.findHandCard handCardId hand ) of
        ( Just realTarget, Just hc ) ->
            case BoardActions.tryHandMerge realTarget hc side of
                Just change ->
                    Hand.setActiveHand (Hand.removeHandCard hc hand)
                        { state
                            | board = applyBoardChange change state.board
                            , cardsPlayedThisTurn = state.cardsPlayedThisTurn + 1
                        }

                Nothing ->
                    let
                        _ =
                            Debug.log "[Execute.mergeHand] tryHandMerge rejected — skipping (rules bug?)"
                                { handCard = handCardId, target = target, side = side }
                    in
                    state

        ( Nothing, _ ) ->
            let
                _ =
                    Debug.log "[Execute.mergeHand] target stack not on board — skipping (bridge bug)" target
            in
            state

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
            state


{-| Place `handCard` on the board at `loc`. Atomically moves the
card from the active hand to a new singleton stack and bumps
`cardsPlayedThisTurn`. Bridge-bug case: hand card not in active
hand → log + state unchanged.
-}
placeHand : Card -> BoardLocation -> GameState -> GameState
placeHand handCardId loc state =
    let
        hand =
            Hand.activeHand state
    in
    case Hand.findHandCard handCardId hand of
        Just hc ->
            Hand.setActiveHand (Hand.removeHandCard hc hand)
                { state
                    | board = applyBoardChange (BoardActions.placeHandCardAt hc loc) state.board
                    , cardsPlayedThisTurn = state.cardsPlayedThisTurn + 1
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
            state



-- HELPERS


applyBoardChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyBoardChange change board =
    List.filter (\s -> not (List.any (isStacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd
