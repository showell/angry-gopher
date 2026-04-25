module Game.Replay.Space exposing
    ( AnimationInfo
    , animatedDragState
    , boardStackSource
    , dragMsPerPixel
    , dragSourceForAction
    , elementTopLeftInViewport
    , handCardForAction
    , handCardSource
    , interpPath
    , linearPath
    , pathDuration
    , pointInLiveViewport
    , stackLandingInLiveViewport
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
DOM measurement of its own. Callers in `Game.Replay.Time` (and
in `Main.elm` for the async HandCardRectReceived continuation)
feed in Model state; this module does the math.

See `Game.Replay.Time` for the companion clock half: which step
are we on, has the beat elapsed, when does the next step fire?

-}

import Browser.Dom
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


{-| The bundle a Time-phase `Animating` carries: when the
animation started, the interpolation path (in the frame named
by `pathFrame`), the DragSource that drives the floater's
render, and the action to apply at end.

No grabOffset — replay speaks only floaterTopLeft; nothing
downstream of capture needs the cursor↔card offset.
-}
type alias AnimationInfo =
    { startMs : Float
    , path : List State.GesturePoint
    , source : DragSource
    , pathFrame : PathFrame
    , pendingAction : WireAction
    }



-- VIEWPORT TRANSLATION (hand-origin target synthesis only)


{-| Convert a `Browser.Dom.Element` to its TOP-LEFT `Point`
in viewport coords. Subtracts `viewport.x/y` so the result is
relative to the browser viewport (matching mouse
`clientX/Y`), not document coords. Used by both hand-origin
Animate modules to seed the animation's starting floater
top-left — the replay floater renders where the hand card
currently sits.
-}
elementTopLeftInViewport : Browser.Dom.Element -> Point
elementTopLeftInViewport element =
    { x = round (element.element.x - element.viewport.x)
    , y = round (element.element.y - element.viewport.y)
    }


{-| Translate a board-frame `{ left, top }` into viewport
frame using the live DOM-measured board rect. Returns
`Nothing` if the rect hasn't arrived yet — callers handle
absence explicitly rather than silently falling back to
pinned constants.
-}
pointInLiveViewport : Model -> { left : Int, top : Int } -> Maybe Point
pointInLiveViewport model loc =
    model.replayBoardRect
        |> Maybe.map
            (\rect ->
                { x = rect.x + loc.left, y = rect.y + loc.top }
            )


{-| Viewport top-left of where a hand-origin merge floater
should LAND when merging onto `stack` on `side`. The hand
card is a single card; after a right-merge it becomes the new
rightmost card of the target stack, so it lands with its
top-left at (target.right, target.top). Left-merge lands at
(target.left - CARD_PITCH, target.top).

Returns `Nothing` if the live board rect isn't ready. Used
by `AnimateMergeHand.finish` to compute the destination of
the synthesized drag path.
-}
stackLandingInLiveViewport : Model -> CardStack -> BoardActions.Side -> Maybe Point
stackLandingInLiveViewport model stack side =
    let
        size =
            CardStack.size stack

        landingLeft =
            case side of
                BoardActions.Right ->
                    stack.loc.left + size * BG.cardPitch

                BoardActions.Left ->
                    stack.loc.left - BG.cardPitch
    in
    pointInLiveViewport model { left = landingLeft, top = stack.loc.top }



-- PATH + INTERPOLATION


{-| Drag duration scales with distance at 2 ms/px — a pace
that reads as natural motion when combined with the eased
synthesis. Applied ONLY to Elm's own synthesized paths
(hand-origin replays). Captured paths carry their pace in
their tMs values and are honored verbatim.
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
to first/last point at the bounds. Returns `Nothing` for an
empty path — callers must handle (treat as "animation done"
or skip).
-}
interpPath : List State.GesturePoint -> Float -> Maybe Point
interpPath path elapsedMs =
    case path of
        [] ->
            Nothing

        first :: _ ->
            let
                targetTs =
                    first.tMs + elapsedMs
            in
            Just (interpPathHelp first path targetTs)


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


{-| Resolve the DragSource for a WireAction against the
current model state. Source identity only — no grabOffset.
-}
dragSourceForAction : WireAction -> Model -> Maybe DragSource
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


boardStackSource : CardStack -> Model -> Maybe DragSource
boardStackSource ref model =
    CardStack.findStack ref model.board
        |> Maybe.map FromBoardStack


handCardSource : Card -> Model -> Maybe DragSource
handCardSource card model =
    let
        hand =
            activeHand model

        present =
            List.any (\hc -> hc.card == card) hand.handCards
    in
    if present then
        Just (FromHandCard card)

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
floater top-left. `floaterTopLeft` is the one field the View
layer reads to position the drag overlay; live-only fields
(cursor, originalCursor, wings, hoveredWing, boardRect,
clickIntent) get stubs — replay doesn't use them.
-}
animatedDragState :
    { a | source : DragSource, pathFrame : PathFrame }
    -> Point
    -> DragState
animatedDragState anim floaterTopLeft =
    Dragging
        { source = anim.source
        , cursor = { x = 0, y = 0 }
        , originalCursor = { x = 0, y = 0 }
        , floaterTopLeft = floaterTopLeft
        , wings = []
        , hoveredWing = Nothing
        , boardRect = Nothing
        , clickIntent = Nothing
        , gesturePath = []
        , pathFrame = anim.pathFrame
        }



