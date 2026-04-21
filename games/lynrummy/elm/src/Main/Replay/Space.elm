module Main.Replay.Space exposing
    ( AnimationInfo
    , animatedDragState
    , buildReplayAnimation
    , dragMsPerPixel
    , dragSourceForAction
    , handCardForAction
    , interpPath
    , linearPath
    , pathDuration
    , pointInLiveViewport
    , stackEdgeInLiveViewport
    , synthesizedReplayAnimation
    , syntheticEndpoints
    )

{-| The spatial half of Instant Replay.

Given a `WireAction` + the current Model, answer **where** the
drag happened in the viewport: where did the cursor start, where
did it go, how long should the interpolation take? Also builds
the `AnimationInfo` record that the Time FSM carries through
its `Animating` phase.

Pure functions only — no Msg, no I/O, no subscriptions, no
DOM measurement of its own. Callers in `Main.Replay.Time` (and
in `Main.elm` for the async HandCardRectReceived continuation)
feed in Model state and already-measured board / hand rects;
this module does the math.

Extracted 2026-04-21 from `Main.elm` alongside the Time module,
to collect ~15 scattered helpers that all answer the same
question: "given an action, where does its drag live in pixel
space?"

See `Main.Replay.Time` for the companion clock half: which step
are we on, has the beat elapsed, when does the next step fire?

-}

import Game.BoardActions as BoardActions
import Game.BoardGeometry as BG
import Game.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack, HandCard)
import Game.WireAction as WA exposing (WireAction)
import Main.State as State
    exposing
        ( DragSource(..)
        , DragState(..)
        , Model
        , Point
        , activeHand
        )



-- ANIMATION INFO


{-| The bundle a Time-phase `Animating` carries through its life:
where the drag starts, its interpolation path, which DragSource
drives the floater rendering, the pointer-to-card offset, and
the action to apply once the interpolation ends.

Same shape as the record inside `State.ReplayAnimation.Animating`
— Elm's structural record typing unifies them.

-}
type alias AnimationInfo =
    { startMs : Float
    , path : List State.GesturePoint
    , source : DragSource
    , grabOffset : Point
    , pendingAction : WireAction
    }



-- BUILD


{-| Build the per-step animation bundle from an action + its
captured path. Returns Nothing when the action type isn't
drag-backed, or when the source card can't be resolved on the
current board/hand (shouldn't happen mid-replay, but total).

The captured path has viewport coordinates for the cursor
position. Grab offset is derived to match the ORIGINAL drag-
start formulas (halfWidth + 20) so the floater sits where
it would have during the real drag.

-}
buildReplayAnimation :
    WireAction
    -> Maybe (List State.GesturePoint)
    -> Model
    -> Float
    -> Maybe AnimationInfo
buildReplayAnimation action maybePath model nowMs =
    let
        faithful path =
            case dragSourceForAction action model of
                Nothing ->
                    Nothing

                Just ( source, grabOffset ) ->
                    Just
                        { startMs = nowMs
                        , path = path
                        , source = source
                        , grabOffset = grabOffset
                        , pendingAction = action
                        }
    in
    case maybePath of
        Just (p :: rest) ->
            faithful (p :: rest)

        _ ->
            synthesizedReplayAnimation action model nowMs


{-| Build an Animating record for an action with no captured
gesture path. Resolves drag endpoints via `syntheticEndpoints`
(live DOM-measured board rect) and synthesizes a linear pointer
path at human-scale velocity. Only covers actions whose
endpoints are BOTH board-frame and can be resolved synchronously
— hand-origin actions go through the async `AwaitingHandRect`
path in `Main.Replay.Time.prepareReplayStep` instead.
-}
synthesizedReplayAnimation : WireAction -> Model -> Float -> Maybe AnimationInfo
synthesizedReplayAnimation action model nowMs =
    case dragSourceForAction action model of
        Nothing ->
            Nothing

        Just ( source, grabOffset ) ->
            case syntheticEndpoints action model of
                Nothing ->
                    Nothing

                Just ( startPt, endPt ) ->
                    Just
                        { startMs = nowMs
                        , path = linearPath startPt endPt nowMs
                        , source = source
                        , grabOffset = grabOffset
                        , pendingAction = action
                        }



-- ENDPOINTS


{-| Synthesize endpoints for a replay drag, in viewport
coords. Only used for SYNCHRONOUS synthesis paths — actions
whose both endpoints can be resolved from the DOM-measured
board rect already in `model.replayBoardRect`.

Hand-origin actions (`MergeHand`, `PlaceHand`) are NOT
handled here — they require an async DOM query for the hand
card's live rect (see `Main.Replay.Time.prepareReplayStep`).

Every viewport coord returned here comes from the live
board rect via `pointInLiveViewport` / `stackEdgeInLiveViewport`
— no direct use of pinned viewport constants. See the
"Rule for adding synthesis" in `Main.claude`.

-}
syntheticEndpoints : WireAction -> Model -> Maybe ( Point, Point )
syntheticEndpoints action model =
    case action of
        WA.MoveStack p ->
            listAt p.stackIndex model.board
                |> Maybe.map
                    (\stack ->
                        let
                            size =
                                CardStack.size stack

                            halfWidth =
                                size * BG.cardPitch // 2

                            halfHeight =
                                BG.cardHeight // 2

                            startLoc =
                                pointInLiveViewport model stack.loc

                            endLoc =
                                pointInLiveViewport model p.newLoc
                        in
                        ( { x = startLoc.x + halfWidth, y = startLoc.y + halfHeight }
                        , { x = endLoc.x + halfWidth, y = endLoc.y + halfHeight }
                        )
                    )

        _ ->
            Nothing


{-| Translate a board-frame `{ left, top }` into the current
viewport frame using the live DOM-measured board rect. Falls
back to documentary constants (with a dev-console log) if the
measurement hasn't arrived.
-}
pointInLiveViewport : Model -> { left : Int, top : Int } -> Point
pointInLiveViewport model loc =
    let
        ( offsetX, offsetY ) =
            case model.replayBoardRect of
                Just rect ->
                    ( rect.x, rect.y )

                Nothing ->
                    let
                        _ =
                            Debug.log "replay: no live board rect yet, using constants"
                                ( BG.boardViewportLeft, BG.boardViewportTop )
                    in
                    ( BG.boardViewportLeft, BG.boardViewportTop )
    in
    { x = offsetX + loc.left, y = offsetY + loc.top }


{-| Viewport point of a stack's left- or right-edge,
vertically centered. Uses the live DOM-measured board rect
(via `pointInLiveViewport`).
-}
stackEdgeInLiveViewport : Model -> CardStack -> BoardActions.Side -> Point
stackEdgeInLiveViewport model stack side =
    let
        size =
            CardStack.size stack

        edgeLeft =
            case side of
                BoardActions.Right ->
                    stack.loc.left + size * BG.cardPitch

                BoardActions.Left ->
                    stack.loc.left

        anchor =
            pointInLiveViewport model { left = edgeLeft, top = stack.loc.top }
    in
    { x = anchor.x, y = anchor.y + BG.cardHeight // 2 }



-- PATH + INTERPOLATION


{-| Drag duration scales with distance at 5 ms/px (tuned by
feel 2026-04-21, from 80 → 15 → 5). Target is perceived
replay pace when watching an agent game, not a measurement
of real human mouse speed. Kept in sync with Python's
`DRAG_MS_PER_PIXEL` in `games/lynrummy/python/gesture_synth.py`
so captured and synthesized paths replay at the same pace.
-}
dragMsPerPixel : Float
dragMsPerPixel =
    5


{-| Build a straight-line path from `start` to `end` with
roughly 12 samples, duration proportional to distance at
`dragMsPerPixel`.
-}
linearPath : Point -> Point -> Float -> List State.GesturePoint
linearPath start end nowMs =
    let
        dx =
            toFloat (end.x - start.x)

        dy =
            toFloat (end.y - start.y)

        dist =
            sqrt (dx * dx + dy * dy)

        duration =
            max 100 (dist * dragMsPerPixel)

        samples =
            12

        step i =
            let
                frac =
                    toFloat i / toFloat (samples - 1)
            in
            { tMs = nowMs + frac * duration
            , x = round (toFloat start.x + dx * frac)
            , y = round (toFloat start.y + dy * frac)
            }
    in
    List.range 0 (samples - 1) |> List.map step


pathDuration : List State.GesturePoint -> Float
pathDuration path =
    case ( List.head path, List.head (List.reverse path) ) of
        ( Just first, Just last ) ->
            last.tMs - first.tMs

        _ ->
            0


{-| Linear-interpolate cursor position along the gesture path.
`elapsedMs` is relative to the first point's timestamp. Clamps
to first/last point at the bounds.
-}
interpPath : List State.GesturePoint -> Float -> Point
interpPath path elapsedMs =
    case path of
        [] ->
            { x = 0, y = 0 }

        first :: _ ->
            let
                targetTs =
                    first.tMs + elapsedMs
            in
            interpPathHelp first path targetTs


interpPathHelp : State.GesturePoint -> List State.GesturePoint -> Float -> Point
interpPathHelp prev remaining targetTs =
    case remaining of
        [] ->
            { x = prev.x, y = prev.y }

        curr :: rest ->
            if curr.tMs >= targetTs then
                if curr.tMs == prev.tMs then
                    { x = curr.x, y = curr.y }

                else
                    let
                        frac =
                            (targetTs - prev.tMs) / (curr.tMs - prev.tMs)

                        frac_ =
                            clamp 0 1 frac
                    in
                    { x = round (toFloat prev.x + frac_ * toFloat (curr.x - prev.x))
                    , y = round (toFloat prev.y + frac_ * toFloat (curr.y - prev.y))
                    }

            else
                interpPathHelp curr rest targetTs



-- DRAG SOURCE


{-| Resolve the DragSource + grabOffset for a WireAction against
the current model state. Mirrors startBoardCardDrag /
startHandDrag offsets so the replay floater matches what the
human saw.
-}
dragSourceForAction : WireAction -> Model -> Maybe ( DragSource, Point )
dragSourceForAction action model =
    case action of
        WA.Split p ->
            boardStackSource p.stackIndex model

        WA.MergeStack p ->
            boardStackSource p.sourceStack model

        WA.MoveStack p ->
            boardStackSource p.stackIndex model

        WA.MergeHand p ->
            handCardSource p.handCard model

        WA.PlaceHand p ->
            handCardSource p.handCard model

        _ ->
            Nothing


boardStackSource : Int -> Model -> Maybe ( DragSource, Point )
boardStackSource stackIndex model =
    listAt stackIndex model.board
        |> Maybe.map
            (\stack ->
                ( FromBoardStack stackIndex
                , { x = CardStack.stackDisplayWidth stack // 2, y = 20 }
                )
            )


handCardSource : Card -> Model -> Maybe ( DragSource, Point )
handCardSource card model =
    let
        hand =
            activeHand model
    in
    handCardIndex card hand.handCards
        |> Maybe.map
            (\idx ->
                ( FromHandCard idx
                , { x = CardStack.stackPitch // 2, y = 20 }
                )
            )


handCardIndex : Card -> List HandCard -> Maybe Int
handCardIndex target cards =
    let
        go i xs =
            case xs of
                [] ->
                    Nothing

                hc :: rest ->
                    if hc.card == target then
                        Just i

                    else
                        go (i + 1) rest
    in
    go 0 cards


{-| Extract the hand card referenced by a hand-origin wire
action, for DOM-id lookup. Returns Nothing for actions that
don't originate in the hand.
-}
handCardForAction : WireAction -> Maybe Card
handCardForAction action =
    case action of
        WA.MergeHand p ->
            Just p.handCard

        WA.PlaceHand p ->
            Just p.handCard

        _ ->
            Nothing



-- RENDER ADAPTER


{-| Synthesize a DragState from an animation bundle + current
cursor. Good enough for `draggedOverlay` to render the floater;
the wings / hoveredWing / clickIntent fields don't matter during
replay animation.
-}
animatedDragState :
    { a | source : DragSource, grabOffset : Point }
    -> Point
    -> DragState
animatedDragState anim cursor =
    Dragging
        { source = anim.source
        , cursor = cursor
        , originalCursor = cursor
        , grabOffset = anim.grabOffset
        , wings = []
        , hoveredWing = Nothing
        , boardRect = Nothing
        , clickIntent = Nothing
        , gesturePath = []
        }



-- INTERNAL


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
