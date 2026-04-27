module Game.Agent.GeometryPlan exposing
    ( defaultBounds
    , planActions
    )

{-| Wrap a stream of WireActions with pre-flight `MoveStack`s
when an in-place merge would violate geometry. Mirrors
`python/strategy._plan_merge_stack`.

Approach: simulate each WireAction against the local board.
If the result is clean, emit it as is. If a merge's in-place
result would violate, find a hole sized for the EVENTUAL
stack (accounting for side-specific offset), inject a
`MoveStack` of the target into that hole, then emit the
merge.

Mid-stack splits are handled by `Game.Agent.Verbs` already
(it pre-moves donors before interior splits via the
isolateCard helper). This module focuses on merges.

-}

import Game.BoardActions as BoardActions
import Game.BoardGeometry as Geometry
    exposing
        ( BoardBounds
        , cardPitch
        , validateBoardGeometry
        )
import Game.CardStack as CardStack exposing (CardStack, stacksEqual)
import Game.PlaceStack as PlaceStack
import Game.WireAction exposing (WireAction(..))


{-| Match the referee's bounds at the canonical viewport.
Mirrors `python/geometry.py`'s `BOARD_MAX_WIDTH/HEIGHT/MARGIN`.
This is the geometry-validation bounds shape (no step
field).
-}
defaultBounds : BoardBounds
defaultBounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


{-| Walk a sequence of WireActions, injecting pre-flight
`MoveStack` primitives ahead of any merge whose in-place
result would violate geometry. Returns the augmented sequence
in send order.
-}
planActions : List CardStack -> List WireAction -> List WireAction
planActions board actions =
    planLoop board actions []


planLoop :
    List CardStack
    -> List WireAction
    -> List WireAction
    -> List WireAction
planLoop board remaining acc =
    case remaining of
        [] ->
            List.reverse acc

        action :: rest ->
            let
                ( emitted, postBoard ) =
                    planOne board action
            in
            planLoop postBoard rest (List.reverse emitted ++ acc)


{-| Plan one WireAction. Returns (emittedSequence, postBoard).
-}
planOne : List CardStack -> WireAction -> ( List WireAction, List CardStack )
planOne board action =
    case action of
        MergeStack p ->
            planMergeStack board p

        _ ->
            ( [ action ], applyOnBoard action board )


planMergeStack :
    List CardStack
    -> { source : CardStack, target : CardStack, side : BoardActions.Side }
    -> ( List WireAction, List CardStack )
planMergeStack board p =
    let
        inPlaceAction =
            MergeStack p

        inPlaceBoard =
            applyOnBoard inPlaceAction board
    in
    if isClean inPlaceBoard then
        ( [ inPlaceAction ], inPlaceBoard )

    else
        case rePlanMergeStack board p of
            Just ( prims, postBoard ) ->
                ( prims, postBoard )

            Nothing ->
                -- Couldn't find a hole. Fall back to the bare
                -- merge; the caller can still send it (the
                -- referee may reject — that's a signal worth
                -- surfacing rather than silently swallowing).
                ( [ inPlaceAction ], inPlaceBoard )


rePlanMergeStack :
    List CardStack
    -> { source : CardStack, target : CardStack, side : BoardActions.Side }
    -> Maybe ( List WireAction, List CardStack )
rePlanMergeStack board p =
    let
        sourceSize =
            List.length p.source.boardCards

        targetSize =
            List.length p.target.boardCards

        finalSize =
            sourceSize + targetSize

        others =
            List.filter
                (\s -> not (stacksEqual s p.source) && not (stacksEqual s p.target))
                board

        finalLoc =
            PlaceStack.findOpenLoc others finalSize

        targetLoc =
            case p.side of
                BoardActions.Left ->
                    { left = finalLoc.left + sourceSize * cardPitch
                    , top = finalLoc.top
                    }

                BoardActions.Right ->
                    finalLoc

        movePrim =
            MoveStack { stack = p.target, newLoc = targetLoc }

        afterMove =
            applyOnBoard movePrim board

        movedTarget =
            -- Look up the moved target by content; its loc is now
            -- targetLoc but content unchanged.
            findByContent p.target afterMove

        movedSource =
            findByContent p.source afterMove
    in
    case ( movedSource, movedTarget ) of
        ( Just src, Just tgt ) ->
            let
                mergePrim =
                    MergeStack { source = src, target = tgt, side = p.side }

                afterMerge =
                    applyOnBoard mergePrim afterMove
            in
            Just ( [ movePrim, mergePrim ], afterMerge )

        _ ->
            Nothing



-- ============================================================
-- Local helpers
-- ============================================================


isClean : List CardStack -> Bool
isClean board =
    List.isEmpty (validateBoardGeometry board defaultBounds)


findByContent : CardStack -> List CardStack -> Maybe CardStack
findByContent ref =
    let
        cardsOf s =
            List.map .card s.boardCards

        refCards =
            cardsOf ref
    in
    List.filter (\s -> cardsOf s == refCards) >> List.head


applyOnBoard : WireAction -> List CardStack -> List CardStack
applyOnBoard action board =
    case action of
        Split { stack, cardIndex } ->
            case findReal stack board of
                Just real ->
                    List.filter (not << stacksEqual real) board
                        ++ CardStack.split cardIndex real

                Nothing ->
                    board

        MergeStack { source, target, side } ->
            case ( findReal source board, findReal target board ) of
                ( Just realSrc, Just realTgt ) ->
                    case BoardActions.tryStackMerge realTgt realSrc side of
                        Just change ->
                            applyChange change board

                        Nothing ->
                            board

                _ ->
                    board

        MoveStack { stack, newLoc } ->
            case findReal stack board of
                Just real ->
                    applyChange
                        (BoardActions.moveStack real newLoc)
                        board

                Nothing ->
                    board

        _ ->
            board


findReal : CardStack -> List CardStack -> Maybe CardStack
findReal target =
    List.filter (stacksEqual target) >> List.head


applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter
        (\s -> not (List.any (stacksEqual s) change.stacksToRemove))
        board
        ++ change.stacksToAdd
