module Game.Agent.GeometryPlan exposing (planActions)

{-| Wrap a stream of WireActions with pre-flight `MoveStack`s
when applying a primitive would land the board in a state where
two stacks overlap (with PACK\_GAP padding — the human-feel
threshold, stricter than the referee's legal margin).

The agent's invariant: after every primitive applies, no two
stacks are within PACK\_GAP of each other. A human player
relocates crowded stacks BEFORE building on them; the agent
matches by injecting MoveStacks at the points where the next
primitive would otherwise produce a too-close result.

This module is the single home for that invariant. Verbs.elm
emits a logical primitive sequence (geometry-agnostic);
`planActions` walks it and inserts pre-flights as needed.

-}

import Game.BoardActions as BoardActions
import Game.BoardGeometry
    exposing
        ( BoardBounds
        , cardPitch
        , validateBoardGeometry
        )
import Game.Card
import Game.CardStack as CardStack exposing (CardStack, stacksEqual)
import Game.PlaceStack as PlaceStack
import Game.WireAction exposing (WireAction(..))


{-| The referee's bounds. Stacks must fit within
800×600 with a 7px legal margin between them.
-}
defaultBounds : BoardBounds
defaultBounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


{-| Walk a sequence of WireActions, injecting pre-flight
`MoveStack`s ahead of any primitive whose post-board would
violate the no-overlap-with-pack-gap invariant.
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


{-| Plan one primitive. The check is diff-based: NEW stacks
(in postBoard but not preBoard) must be pack-gap-clear from
PRE-EXISTING stacks (stacks that survived). Split siblings
(new-vs-new pairs) are exempt — they're inherently close by
the +8px split offset, which isn't a primitive emitting an
overlap with the rest of the board.

If post-state respects the invariant, emit as is. Otherwise
try a pre-flight MoveStack to a clear spot, then re-emit. If
pre-flight can't find a clear loc, fall back to the bare
primitive; the referee may still accept (legal margin).

-}
planOne : List CardStack -> WireAction -> ( List WireAction, List CardStack )
planOne board action =
    let
        -- Re-resolve the action's stack refs against the
        -- CURRENT board. Verbs.elm emits WireActions whose
        -- stack snapshots carry locs from a sim that doesn't
        -- include prior planActions pre-flights; resolving
        -- here lets the action correctly target stacks that
        -- have moved.
        resolved =
            resolveAction board action

        postBoard =
            applyOnBoard resolved board
    in
    if isCleanAfterAction board postBoard then
        ( [ resolved ], postBoard )

    else
        case preFlight board resolved of
            Just ( movePrim, newAction, newPostBoard ) ->
                ( [ movePrim, newAction ], newPostBoard )

            Nothing ->
                ( [ resolved ], postBoard )


{-| Re-look-up a WireAction's stack references against the
current board. Stack identity is by content (cards in order);
the carried `loc` may be stale because earlier planActions
pre-flights moved the stack.
-}
resolveAction : List CardStack -> WireAction -> WireAction
resolveAction board action =
    case action of
        Split p ->
            case findByContent p.stack board of
                Just live ->
                    Split { p | stack = live }

                Nothing ->
                    action

        MergeStack p ->
            case ( findByContent p.source board, findByContent p.target board ) of
                ( Just src, Just tgt ) ->
                    MergeStack { p | source = src, target = tgt }

                _ ->
                    action

        MoveStack p ->
            case findByContent p.stack board of
                Just live ->
                    MoveStack { p | stack = live }

                Nothing ->
                    action

        _ ->
            action


{-| Compute a pre-flight MoveStack for a primitive whose
post-board would overlap. Returns
`(movePrim, primitive-against-moved-board, post-state)` or
Nothing if no helpful pre-flight exists for this primitive
shape (e.g., MoveStack itself).
-}
preFlight :
    List CardStack
    -> WireAction
    -> Maybe ( WireAction, WireAction, List CardStack )
preFlight board action =
    case action of
        Split p ->
            preFlightSplit board p.stack p.cardIndex

        MergeStack p ->
            preFlightMerge board p.source p.target p.side

        _ ->
            Nothing


{-| Move the source stack to a pack-gap-cleared loc with room
for the source's full size, then re-emit the split. The post-
split spawn lands within the source's relocated footprint, so
this also clears the spawn.
-}
preFlightSplit :
    List CardStack
    -> CardStack
    -> Int
    -> Maybe ( WireAction, WireAction, List CardStack )
preFlightSplit board stack cardIndex =
    let
        sourceSize =
            List.length stack.boardCards

        others =
            List.filter (not << stacksEqual stack) board

        newLoc =
            PlaceStack.findOpenLoc others sourceSize
    in
    if newLoc == stack.loc then
        Nothing

    else
        let
            movePrim =
                MoveStack { stack = stack, newLoc = newLoc }

            afterMove =
                applyOnBoard movePrim board
        in
        case findByContent stack afterMove of
            Just relocated ->
                let
                    newSplit =
                        Split { stack = relocated, cardIndex = cardIndex }

                    afterSplit =
                        applyOnBoard newSplit afterMove
                in
                Just ( movePrim, newSplit, afterSplit )

            Nothing ->
                Nothing


{-| Move the merge target to a pack-gap-cleared loc that fits
the augmented (source.size + target.size) stack, then re-emit
the merge. Mirrors what the old `rePlanMergeStack` did.
-}
preFlightMerge :
    List CardStack
    -> CardStack
    -> CardStack
    -> BoardActions.Side
    -> Maybe ( WireAction, WireAction, List CardStack )
preFlightMerge board source target side =
    let
        sourceSize =
            List.length source.boardCards

        targetSize =
            List.length target.boardCards

        finalSize =
            sourceSize + targetSize

        others =
            List.filter
                (\s -> not (stacksEqual s source) && not (stacksEqual s target))
                board

        finalLoc =
            PlaceStack.findOpenLoc others finalSize

        targetLoc =
            case side of
                BoardActions.Left ->
                    { left = finalLoc.left + sourceSize * cardPitch
                    , top = finalLoc.top
                    }

                BoardActions.Right ->
                    finalLoc
    in
    if targetLoc == target.loc then
        Nothing

    else
        let
            movePrim =
                MoveStack { stack = target, newLoc = targetLoc }

            afterMove =
                applyOnBoard movePrim board

            movedTarget =
                findByContent target afterMove

            movedSource =
                findByContent source afterMove
        in
        case ( movedSource, movedTarget ) of
            ( Just src, Just tgt ) ->
                let
                    newMerge =
                        MergeStack { source = src, target = tgt, side = side }

                    afterMerge =
                        applyOnBoard newMerge afterMove
                in
                Just ( movePrim, newMerge, afterMerge )

            _ ->
                Nothing



-- ============================================================
-- Local helpers
-- ============================================================


{-| Diff-based pack-gap check: new stacks (in postBoard but
not preBoard) must be pack-gap-clear from pre-existing stacks
(stacks that survived from preBoard to postBoard). New-vs-new
pairs (split siblings) are exempt.

Out-of-bounds and pure overlap apply to all stacks
unconditionally via the legal-margin validator.

-}
isCleanAfterAction : List CardStack -> List CardStack -> Bool
isCleanAfterAction preBoard postBoard =
    let
        preKeys =
            List.map stackKey preBoard

        preExisting =
            List.filter (\s -> List.member (stackKey s) preKeys) postBoard

        newStacks =
            List.filter (\s -> not (List.member (stackKey s) preKeys)) postBoard

        legalErrors =
            validateBoardGeometry postBoard defaultBounds
    in
    if not (List.isEmpty legalErrors) then
        False

    else
        not (List.any (anyPackGapOverlap preExisting) newStacks)


anyPackGapOverlap : List CardStack -> CardStack -> Bool
anyPackGapOverlap preExisting newStack =
    let
        rect =
            stackBoundingRect newStack

        padded =
            { left = rect.left - 30
            , top = rect.top - 30
            , right = rect.right + 30
            , bottom = rect.bottom + 30
            }
    in
    List.any
        (\old ->
            let
                otherRect =
                    stackBoundingRect old
            in
            padded.left
                < otherRect.right
                && padded.right
                > otherRect.left
                && padded.top
                < otherRect.bottom
                && padded.bottom
                > otherRect.top
        )
        preExisting


stackBoundingRect : CardStack -> { left : Int, top : Int, right : Int, bottom : Int }
stackBoundingRect s =
    let
        n =
            List.length s.boardCards

        width =
            if n <= 0 then
                0

            else
                27 + (n - 1) * cardPitch
    in
    { left = s.loc.left
    , top = s.loc.top
    , right = s.loc.left + width
    , bottom = s.loc.top + 40
    }


stackKey : CardStack -> ( CardStack.BoardLocation, List Game.Card.Card )
stackKey s =
    ( s.loc, List.map .card s.boardCards )


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
