module Game.Replay.HandDragAnimate exposing
    ( Outcome(..)
    , State
    , dragInfo
    , measurementReceived
    , start
    , step
    )

{-| The hand-drag sub-state-machine for Instant Replay.

Hand-drag animation has three stages, all owned here:

  - **NotYetMeasured** — just popped off the queue. The
    next `step` emits `NeedsMeasurement` (transitioning
    self to `AwaitingMeasurement`) so the host fires its
    DOM query exactly once.
  - **AwaitingMeasurement** — request is in flight. `step`
    is idle here. `measurementReceived` consumes the
    response and transitions to `InFlight`.
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
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.HandDragTypes exposing (HandCardDragInfo)
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.Rules.Card exposing (Card)
import Game.TimeLoc exposing (TimeLoc)


type State
    = NotYetMeasured ActionLogEntry
    | AwaitingMeasurement ActionLogEntry
    | InFlight InFlightData


type alias InFlightData =
    { path : List TimeLoc
    , startMs : Int
    , pendingAction : GameEvent
    , dragInfo_ : HandCardDragInfo
    }


type Outcome
    = InProgress State
    | NeedsMeasurement State Card
    | Done { newGameState : GameState }


start : ActionLogEntry -> State
start entry =
    NotYetMeasured entry


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

        _ ->
            -- Late result (e.g., resolution after a
            -- pause-toggle drove us past the awaiting
            -- stage). Drop it.
            state


{-| Per-frame access to the floater data the View renders.
`Nothing` while pre-flight (no floater yet); `Just info`
once InFlight.
-}
dragInfo : State -> Maybe HandCardDragInfo
dragInfo state =
    case state of
        InFlight d ->
            Just d.dragInfo_

        _ ->
            Nothing


step : Int -> GameState -> State -> Outcome
step nowMs gameState state =
    case state of
        NotYetMeasured entry ->
            -- First tick after pop. Emit the measurement
            -- request exactly once and advance the substate
            -- so subsequent ticks don't refire it.
            NeedsMeasurement (AwaitingMeasurement entry) (handCardOf entry.action)

        AwaitingMeasurement _ ->
            -- Idle; the host's measurement Cmd is in flight.
            InProgress state

        InFlight d ->
            let
                elapsedMs =
                    toFloat (nowMs - d.startMs)
            in
            if elapsedMs >= duration d.path then
                Done { newGameState = Execute.applyEvent d.pendingAction gameState }

            else
                InProgress
                    (InFlight
                        { d | dragInfo_ = setFloater (interp d.path elapsedMs) d.dragInfo_ }
                    )


handCardOf : GameEvent -> Card
handCardOf action =
    case action of
        GameEvent.MergeHand p ->
            p.handCard

        GameEvent.PlaceHand p ->
            p.handCard

        _ ->
            Debug.todo
                "HandDragAnimate.handCardOf: NotYetMeasured entry must carry a hand action"



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
