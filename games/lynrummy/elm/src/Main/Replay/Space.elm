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
    )

{-| The spatial half of Instant Replay.

Given a `WireAction` + the current Model, answer **where** the
drag happened — AND in **which frame**. The board is a self-
contained widget; for intra-board drags, coords live in
board frame and the floater is rendered as a DOM child of the
board div so CSS handles board→viewport for free. Hand-origin
drags cross the board widget boundary and use viewport coords;
for those we DOM-measure at replay time.

Pure functions only — no Msg, no I/O, no subscriptions, no
DOM measurement of its own. Callers in `Main.Replay.Time` (and
in `Main.elm` for the async HandCardRectReceived continuation)
feed in Model state; this module does the math.

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
        , PathFrame(..)
        , Point
        , activeHand
        )



-- ANIMATION INFO


{-| The bundle a Time-phase `Animating` carries through its life:
where the drag starts, its interpolation path (in the frame
named by `pathFrame`), which DragSource drives the floater
rendering, the pointer-to-card offset, and the action to apply
once the interpolation ends.

Same shape as the record inside `State.ReplayAnimation.Animating`
— Elm's structural record typing unifies them.

-}
type alias AnimationInfo =
    { startMs : Float
    , path : List State.GesturePoint
    , source : DragSource
    , grabOffset : Point
    , pathFrame : PathFrame
    , pendingAction : WireAction
    }



-- BUILD


{-| Build the per-step animation bundle from an action + its
captured path. Returns Nothing only when the source card can't
be resolved on the current board/hand — a contract violation
(the replay state and the wire's CardStack refs have drifted
apart), but total so the FSM can recover.

The server enforces that intra-board actions carry a path
(see `views/lynrummy_elm.go`'s `requiresGestureMetadata`), so
this function is always called with a non-empty path for
drag-backed actions. Hand-origin actions without a path take
the async DOM-measurement branch in `Main.Replay.Time`
instead.

-}
buildReplayAnimation :
    WireAction
    -> List State.GesturePoint
    -> PathFrame
    -> Model
    -> Float
    -> Maybe AnimationInfo
buildReplayAnimation action path frame model nowMs =
    dragSourceForAction action model
        |> Maybe.map
            (\( source, grabOffset ) ->
                { startMs = nowMs
                , path = path
                , source = source
                , grabOffset = grabOffset
                , pathFrame = frame
                , pendingAction = action
                }
            )



-- VIEWPORT TRANSLATION (hand-origin target synthesis only)


{-| Translate a board-frame `{ left, top }` into the current
viewport frame using the live DOM-measured board rect. Falls
back to documentary constants (with a dev-console log) if the
measurement hasn't arrived. Used by
`Main.Replay.Time.handCardRectReceived` to land a PlaceHand
drop target in viewport frame.
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


{-| Viewport point of a stack's left- or right-edge, vertically
centered. Used by `handCardRectReceived` in Time: hand-origin
drags cross the board widget boundary, so their target must be
in viewport frame.
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


{-| Drag duration scales with distance at 2 ms/px (Steve,
2026-04-21: settled pace for perceived replay readability now
that the eased synthesis carries shape information). Decoupled
from Python's `DRAG_MS_PER_PIXEL` — Python-captured paths carry
their pace in their tMs values and Elm honors them verbatim;
this constant governs ONLY Elm's own synthesis (hand-origin
linearPath target construction).
-}
dragMsPerPixel : Float
dragMsPerPixel =
    2


{-| Build a straight-line path from `start` to `end`, duration
proportional to distance at `dragMsPerPixel`. The returned
samples' coordinate frame matches `start` and `end`'s frame —
the caller is responsible for being consistent.
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
            boardStackSource p.stack model

        WA.MergeStack p ->
            boardStackSource p.source model

        WA.MoveStack p ->
            boardStackSource p.stack model

        WA.MergeHand p ->
            handCardSource p.handCard model

        WA.PlaceHand p ->
            handCardSource p.handCard model

        _ ->
            Nothing


boardStackSource : CardStack -> Model -> Maybe ( DragSource, Point )
boardStackSource ref model =
    CardStack.findStack ref model.board
        |> Maybe.map
            (\stack ->
                ( FromBoardStack stack
                , { x = CardStack.stackDisplayWidth stack // 2, y = 20 }
                )
            )


handCardSource : Card -> Model -> Maybe ( DragSource, Point )
handCardSource card model =
    let
        hand =
            activeHand model

        present =
            List.any (\hc -> hc.card == card) hand.handCards
    in
    if present then
        Just
            ( FromHandCard card
            , { x = CardStack.stackPitch // 2, y = 20 }
            )

    else
        Nothing


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
cursor. Good enough for the drag overlay to render the floater;
the wings / hoveredWing / clickIntent fields don't matter during
replay animation. The `pathFrame` from the anim is carried into
the DragInfo so the View layer can pick the right rendering
parent (board child for BoardFrame; viewport overlay for
ViewportFrame).
-}
animatedDragState :
    { a | source : DragSource, grabOffset : Point, pathFrame : PathFrame }
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
        , pathFrame = anim.pathFrame
        }



