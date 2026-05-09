module Game.Replay.Space exposing
    ( AnimationInfo
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

Given a `GameEvent` + the current state, answer **where** the
drag happened. Board-origin paths live in board frame; hand-
origin paths live in viewport frame and are synthesized at
replay time via DOM measurement.

Pure functions only — no Msg, no I/O, no subscriptions.

See `Game.Replay.Time` for the companion clock half.

-}

import Browser.Dom
import Game.BoardActions as BoardActions
import Game.CardStack as CardStack exposing (CardStack)
import Game.Drag exposing (DragSource(..))
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.Hand as Hand
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.Rules.Card exposing (Card)
import Game.TimeLoc exposing (TimeLoc)
import Game.Point exposing (Point)



-- ANIMATION INFO


{-| The bundle a Time-phase `Animating` carries: when the
animation started, the interpolation path (in the frame
implied by `source`'s variant — board for `FromBoardStack`,
viewport for `FromHandCard`), the source identity that drives
the floater's render, and the action to apply at end.
-}
type alias AnimationInfo =
    { startMs : Float
    , path : List TimeLoc
    , source : DragSource
    , pendingAction : GameEvent
    }



-- VIEWPORT TRANSLATION (hand-origin target synthesis only)


elementTopLeftInViewport : Browser.Dom.Element -> Point
elementTopLeftInViewport element =
    { x = round (element.element.x - element.viewport.x)
    , y = round (element.element.y - element.viewport.y)
    }


pointInLiveViewport : Maybe GA.Rect -> { left : Int, top : Int } -> Maybe Point
pointInLiveViewport maybeRect loc =
    maybeRect
        |> Maybe.map
            (\rect ->
                { x = rect.x + loc.left, y = rect.y + loc.top }
            )


stackLandingInLiveViewport : Maybe GA.Rect -> CardStack -> BoardActions.Side -> Maybe Point
stackLandingInLiveViewport maybeRect stack side =
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
    pointInLiveViewport maybeRect { left = landingLeft, top = stack.loc.top }



-- PATH + INTERPOLATION


dragMsPerPixel : Float
dragMsPerPixel =
    2.5


linearPath : Point -> Point -> Float -> List TimeLoc
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
            , left = round (toFloat start.x + dx * frac)
            , top = round (toFloat start.y + dy * frac)
            }
    in
    List.range 0 (samples - 1) |> List.map step


easedPath : Point -> Point -> Float -> List TimeLoc
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
            , left = round (toFloat start.x + dx * pos)
            , top = round (toFloat start.y + dy * pos)
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


{-| Synthesize a fresh board-frame path for `action`. Returns
`Nothing` if synthesis can't honestly be done (Splits, hand-
origin actions). The agent-play flow relies on this — agent-
emitted primitives carry no captured path.
-}
synthesizeBoardPath : GameEvent -> List CardStack -> Float -> Maybe (List TimeLoc)
synthesizeBoardPath action board nowMs =
    boardEndpoints action board
        |> Maybe.map
            (\( start, end ) ->
                easedPath start end nowMs
            )


boardEndpoints : GameEvent -> List CardStack -> Maybe ( Point, Point )
boardEndpoints action board =
    case action of
        GameEvent.MoveStack p ->
            CardStack.findStack p.stack board
                |> Maybe.map
                    (\src ->
                        ( { x = src.loc.left, y = src.loc.top }
                        , { x = p.newLoc.left, y = p.newLoc.top }
                        )
                    )

        GameEvent.MergeStack p ->
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
                (CardStack.findStack p.source board)
                (CardStack.findStack p.target board)

        _ ->
            Nothing


{-| Decide whether a captured path is still trustworthy
against the live board. The first sample's loc should match
the source stack's current `loc`. If a stack moved since
capture (e.g. the agent's geometry pre-flight ran ahead),
discard and let `synthesizeBoardPath` build a fresh one.
-}
isPathStillValid : List TimeLoc -> GameEvent -> List CardStack -> Bool
isPathStillValid path action board =
    case ( List.head path, expectedStartFor action board ) of
        ( Just first, Just expected ) ->
            first.left == expected.x && first.top == expected.y

        ( _, Nothing ) ->
            True

        ( Nothing, _ ) ->
            False


expectedStartFor : GameEvent -> List CardStack -> Maybe Point
expectedStartFor action board =
    boardEndpoints action board
        |> Maybe.map Tuple.first


pathDuration : List TimeLoc -> Float
pathDuration path =
    case ( List.head path, List.head (List.reverse path) ) of
        ( Just first, Just last ) ->
            last.tMs - first.tMs

        _ ->
            0


{-| Linear-interpolate cursor position along the path.
`elapsedMs` is relative to the first sample's timestamp.
Returns `Nothing` for an empty path.
-}
interpPath : List TimeLoc -> Float -> Maybe Point
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


interpPathHelp : TimeLoc -> List TimeLoc -> Float -> Point
interpPathHelp prev remaining targetTs =
    case remaining of
        [] ->
            { x = prev.left, y = prev.top }

        curr :: rest ->
            if curr.tMs >= targetTs then
                if curr.tMs == prev.tMs then
                    { x = curr.left, y = curr.top }

                else
                    let
                        frac =
                            (targetTs - prev.tMs) / (curr.tMs - prev.tMs)

                        frac_ =
                            clamp 0 1 frac
                    in
                    { x = round (toFloat prev.left + frac_ * toFloat (curr.left - prev.left))
                    , y = round (toFloat prev.top + frac_ * toFloat (curr.top - prev.top))
                    }

            else
                interpPathHelp curr rest targetTs



-- DRAG SOURCE


boardStackSource : CardStack -> List CardStack -> Maybe DragSource
boardStackSource ref board =
    CardStack.findStack ref board
        |> Maybe.map FromBoardStack


handCardSource : Card -> GameState -> Maybe DragSource
handCardSource card gameState =
    let
        hand =
            Hand.activeHand gameState

        present =
            List.any (\hc -> hc.card == card) hand.handCards
    in
    if present then
        Just (FromHandCard card)

    else
        Nothing

