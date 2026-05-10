module Game.Replay.HandDragAnimate exposing
    ( Outcome(..)
    , State
    , dragInfo
    , measurementReceived
    , measureRequest
    , start
    , step
    )

{-| The hand-drag sub-state-machine for Instant Replay.

Hand-drag animation has two stages, both owned here:

  - **AwaitingMeasurement** — the floater can't render until
    we know the hand card's live viewport position and the
    board's live offset. The state holds the popped entry
    and waits. `measureRequest` exposes which card the host
    should DOM-measure; `measurementReceived` transitions
    to the in-flight stage with a synthesized linear path.
  - **InFlight** — the path is being interpolated; each
    `step` advances the floater. `Done` fires when the
    path's duration has elapsed.

Same shape for `MergeHand` and `PlaceHand` — the merge-vs-
place distinction matters at landing time (handled by
`Execute.applyEvent` in the outer machine) and at
destination computation (a stack-side adjacency vs. an
explicit board location, dispatched inside
`measurementReceived`); the in-flight visual is identical.

-}

import Browser.Dom
import Game.ActionLog exposing (ActionLogEntry)
import Game.BoardActions as BoardActions
import Game.CardStack as CardStack
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.HandDragTypes exposing (HandCardDragInfo)
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.Rules.Card exposing (Card)
import Game.TimeLoc exposing (TimeLoc)


type State
    = AwaitingMeasurement ActionLogEntry
    | InFlight InFlightData


type alias InFlightData =
    { path : List TimeLoc
    , startMs : Int
    , pendingAction : GameEvent
    , dragInfo_ : HandCardDragInfo
    }


type Outcome
    = InProgress State
    | Done { pendingAction : GameEvent }


start : ActionLogEntry -> State
start entry =
    AwaitingMeasurement entry


{-| The hand card the host should DOM-measure, or Nothing
once the animation has progressed past the measurement
stage. The outer machine emits its `NeedHandCardRect` signal
exactly when this returns `Just`.
-}
measureRequest : State -> Maybe Card
measureRequest state =
    case state of
        AwaitingMeasurement entry ->
            case entry.action of
                GameEvent.MergeHand p ->
                    Just p.handCard

                GameEvent.PlaceHand p ->
                    Just p.handCard

                _ ->
                    Debug.todo
                        "HandDragAnimate.measureRequest: AwaitingMeasurement entry must carry a hand action"

        InFlight _ ->
            Nothing


{-| Host calls this when the bundled DOM query resolves.
Builds the linear path from origin (hand card's viewport
top-left) to destination (computed from the action's
payload + the live board rect) and transitions to InFlight.

Both rects are extracted here, so callers in the outer
machine don't have to know the conversion.

-}
measurementReceived :
    Int
    -> Browser.Dom.Element
    -> Browser.Dom.Element
    -> State
    -> State
measurementReceived nowMs handElement boardElement state =
    case state of
        AwaitingMeasurement entry ->
            let
                origin =
                    elementTopLeftInViewport handElement

                boardRect =
                    boardRectFromElement boardElement
            in
            InFlight (buildInFlight entry origin boardRect nowMs)

        InFlight _ ->
            -- Late result (e.g., second resolution after a
            -- pause-toggle). Drop it.
            state


{-| Per-frame access to the floater data the View renders.
`Nothing` while AwaitingMeasurement (the floater hasn't
appeared yet); `Just info` once InFlight.
-}
dragInfo : State -> Maybe HandCardDragInfo
dragInfo state =
    case state of
        AwaitingMeasurement _ ->
            Nothing

        InFlight d ->
            Just d.dragInfo_


step : Int -> State -> Outcome
step nowMs state =
    case state of
        AwaitingMeasurement _ ->
            -- Idle; the host's measurement Cmd is in flight.
            InProgress state

        InFlight d ->
            let
                elapsedMs =
                    toFloat (nowMs - d.startMs)
            in
            if elapsedMs >= duration d.path then
                Done { pendingAction = d.pendingAction }

            else
                InProgress
                    (InFlight
                        { d | dragInfo_ = setFloater (interp d.path elapsedMs) d.dragInfo_ }
                    )



-- IN-FLIGHT CONSTRUCTION


{-| Synthesize the linear path + initial drag info for a
popped hand action. Dispatches by variant to compute the
floater's destination in viewport coords, then composes
`linearPath` + a fresh `HandCardDragInfo`.
-}
buildInFlight : ActionLogEntry -> Point -> GA.Rect -> Int -> InFlightData
buildInFlight entry origin boardRect nowMs =
    case entry.action of
        GameEvent.MergeHand p ->
            let
                size =
                    CardStack.size p.target

                landingLeft =
                    case p.side of
                        BoardActions.Right ->
                            p.target.loc.left + size * BG.cardPitch

                        BoardActions.Left ->
                            p.target.loc.left - BG.cardPitch
            in
            inFlightFor
                { handCard = p.handCard
                , origin = origin
                , destination =
                    { x = boardRect.x + landingLeft
                    , y = boardRect.y + p.target.loc.top
                    }
                , startMs = nowMs
                , pendingAction = entry.action
                }

        GameEvent.PlaceHand p ->
            inFlightFor
                { handCard = p.handCard
                , origin = origin
                , destination =
                    { x = boardRect.x + p.loc.left
                    , y = boardRect.y + p.loc.top
                    }
                , startMs = nowMs
                , pendingAction = entry.action
                }

        _ ->
            Debug.todo
                "HandDragAnimate.buildInFlight: AwaitingMeasurement entry must carry a hand action"


inFlightFor :
    { handCard : Card
    , origin : Point
    , destination : Point
    , startMs : Int
    , pendingAction : GameEvent
    }
    -> InFlightData
inFlightFor { handCard, origin, destination, startMs, pendingAction } =
    { path = linearPath origin destination (toFloat startMs)
    , startMs = startMs
    , pendingAction = pendingAction
    , dragInfo_ =
        { card = handCard
        , cursor = origin
        , floaterTopLeft = origin
        , wings = []
        }
    }



-- DOM GEOMETRY


elementTopLeftInViewport : Browser.Dom.Element -> Point
elementTopLeftInViewport element =
    { x = round (element.element.x - element.viewport.x)
    , y = round (element.element.y - element.viewport.y)
    }


boardRectFromElement : Browser.Dom.Element -> GA.Rect
boardRectFromElement element =
    { x = round (element.element.x - element.viewport.x)
    , y = round (element.element.y - element.viewport.y)
    , width = round element.element.width
    , height = round element.element.height
    }



-- PATH MATH


setFloater : Point -> HandCardDragInfo -> HandCardDragInfo
setFloater p info =
    { info | floaterTopLeft = p, cursor = p }


duration : List TimeLoc -> Float
duration path =
    case ( List.head path, List.head (List.reverse path) ) of
        ( Just first, Just last ) ->
            last.tMs - first.tMs

        _ ->
            0


{-| Sample a straight-line path between two viewport-frame
points. Duration scales with distance so short hops feel
brisk and long hops feel deliberate; the floor avoids
zero-duration paths if origin and destination collide.
-}
linearPath : Point -> Point -> Float -> List TimeLoc
linearPath start_ end startMs =
    let
        dx =
            toFloat (end.x - start_.x)

        dy =
            toFloat (end.y - start_.y)

        dist =
            sqrt (dx * dx + dy * dy)

        dragMsPerPixel =
            2.5

        totalMs =
            max 100 (dist * dragMsPerPixel)

        samples =
            12

        sample i =
            let
                frac =
                    toFloat i / toFloat (samples - 1)
            in
            { tMs = startMs + frac * totalMs
            , left = round (toFloat start_.x + dx * frac)
            , top = round (toFloat start_.y + dy * frac)
            }
    in
    List.range 0 (samples - 1) |> List.map sample


interp : List TimeLoc -> Float -> Point
interp path elapsedMs =
    case path of
        [] ->
            { x = 0, y = 0 }

        first :: _ ->
            interpHelp first path (first.tMs + elapsedMs)


interpHelp : TimeLoc -> List TimeLoc -> Float -> Point
interpHelp prev remaining targetTs =
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
                            clamp 0 1 ((targetTs - prev.tMs) / (curr.tMs - prev.tMs))
                    in
                    { x = round (toFloat prev.left + frac * toFloat (curr.left - prev.left))
                    , y = round (toFloat prev.top + frac * toFloat (curr.top - prev.top))
                    }

            else
                interpHelp curr rest targetTs
