module Game.Replay.Space exposing
    ( AnimationInfo
    , animatedDragState
    , boardStackSource
    , elementTopLeftInViewport
    , handCardSource
    , interpPath
    , linearPath
    , pathDuration
    , isPathStillValid
    , pointInLiveViewport
    , stackLandingInLiveViewport
    , synthesizeBoardPath
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
import Game.Rules.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack)
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
(target.left - CARD\_PITCH, target.top).

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


{-| Drag duration scales with distance. Verbatim from Python's
`gesture_synth.DRAG_MS_PER_PIXEL = 2.5`. The pace is perceptual
(a fluent-human drag pace), not a measurement of real human
mouse speed. Applied to Elm's synthesized paths; captured
paths carry their own pace in their tMs values.
-}
dragMsPerPixel : Float
dragMsPerPixel =
    2.5


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


{-| Quintic-eased path from `start` to `end`, sampled at uniform
time intervals. Verbatim port of Python's
`gesture_synth.synthesize`: ease curve `6f⁵ − 15f⁴ + 10f³`
(quintic smootherstep — peak velocity at the midpoint, zero
derivative AND zero second derivative at both ends, so the
floater eases out of rest and into rest more pronouncedly than
cosine). 20 samples is dense enough that linear interpolation
between them reads smoothly through the fast middle.
-}
easedPath : Point -> Point -> Float -> List State.GesturePoint
easedPath start end nowMs =
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
            20

        step i =
            let
                frac =
                    toFloat i / toFloat (samples - 1)

                pos =
                    quinticEase frac
            in
            { tMs = nowMs + frac * duration
            , x = round (toFloat start.x + dx * pos)
            , y = round (toFloat start.y + dy * pos)
            }
    in
    List.range 0 (samples - 1) |> List.map step


quinticEase : Float -> Float
quinticEase f =
    let
        f3 =
            f * f * f
    in
    f3 * (f * (f * 6 - 15) + 10)



-- BOARD-ORIGIN PATH SYNTHESIS (the JIT seam)
--
-- Mirrors Python's `gesture_synth.drag_endpoints`: given a
-- WireAction and the live board, derive the (start, end) pair
-- in board frame, then build an eased path. Hand-origin
-- primitives and Splits return Nothing (the former goes
-- through the async DOM-measurement path, the latter is a
-- click and isn't animated at all).


{-| Synthesize a fresh gesture path for `action` against the
live `model`. Returns the path together with the frame it lives
in, or `Nothing` if synthesis can't honestly be done for this
action shape.

This is the "JIT" half of the Replay runtime. Whenever a
captured gesture path is missing or stale,
`Game.Replay.Time.prepareReplayStep` calls this to manufacture
one on the fly. The agent-play flow specifically relies on
this path: agent-emitted primitives carry no captured gesture,
so every drag the player sees is synthesized here.

-}
synthesizeBoardPath :
    WireAction
    -> Model
    -> Float
    -> Maybe ( List State.GesturePoint, PathFrame )
synthesizeBoardPath action model nowMs =
    boardEndpoints action model
        |> Maybe.map
            (\( start, end ) ->
                ( easedPath start end nowMs, BoardFrame )
            )


{-| Resolve `(start, end)` board-frame floater-top-left points
for a board-origin primitive against the live board. Mirrors
Python's `drag_endpoints` exactly so paths look the same on
both sides:

  - `MoveStack`: src.loc → newLoc.
  - `MergeStack` right side: src.loc → (target.left + target.size \* pitch + 2,
    target.top - 2). The +2 / -2 jitter is the same pixel-perfect
    offset Python emits to keep the landing from looking
    machine-tidied.
  - `MergeStack` left side: src.loc → (target.left - src.size \* pitch + 2,
    target.top - 2).
  - `Split`, hand-origin actions: `Nothing` — Splits are clicks
    in the live UI (the live click event produces a single
    redraw with no floater; replay matches), and hand origins
    aren't pinned in board coords.

-}
boardEndpoints : WireAction -> Model -> Maybe ( Point, Point )
boardEndpoints action model =
    case action of
        WA.MoveStack p ->
            CardStack.findStack p.stack model.board
                |> Maybe.map
                    (\src ->
                        ( { x = src.loc.left, y = src.loc.top }
                        , { x = p.newLoc.left, y = p.newLoc.top }
                        )
                    )

        WA.MergeStack p ->
            Maybe.map2
                (\src tgt ->
                    let
                        srcSize =
                            CardStack.size src

                        tgtSize =
                            CardStack.size tgt

                        endLeft =
                            case p.side of
                                BoardActions.Right ->
                                    tgt.loc.left + tgtSize * BG.cardPitch

                                BoardActions.Left ->
                                    tgt.loc.left - srcSize * BG.cardPitch
                    in
                    ( { x = src.loc.left, y = src.loc.top }
                    , { x = endLeft + 2, y = tgt.loc.top - 2 }
                    )
                )
                (CardStack.findStack p.source model.board)
                (CardStack.findStack p.target model.board)

        _ ->
            Nothing


{-| Decide whether a captured gesture path is still trustworthy
against the live board. Path samples are floater-top-left
points, so the first sample should match the source stack's
current `loc`. If a stack has been MovedStack since the path
was captured (e.g. the agent's geometry pre-flight ran ahead),
the start point is stale and the path would draw a phantom
trajectory; in that case we discard it and let
`synthesizeBoardPath` build a fresh one.

The check is intentionally conservative: any miss → re-synth.
A few-pixel difference is rare in practice (locs are integer
and paths are recorded with the exact loc), so this isn't a
fuzzy match.

-}
isPathStillValid : List State.GesturePoint -> WireAction -> Model -> Bool
isPathStillValid path action model =
    case ( List.head path, expectedStartFor action model ) of
        ( Just first, Just expected ) ->
            first.x == expected.x && first.y == expected.y

        ( _, Nothing ) ->
            -- No expectation we can check (hand-origin, split,
            -- or unknown shape). Trust the captured path —
            -- the JIT fallback only kicks in when we can
            -- actively prove staleness.
            True

        ( Nothing, _ ) ->
            -- Empty path → not valid; let the caller decide
            -- (today: synthesize or applyImmediate).
            False


expectedStartFor : WireAction -> Model -> Maybe Point
expectedStartFor action model =
    boardEndpoints action model
        |> Maybe.map Tuple.first


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
