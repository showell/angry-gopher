module Lib.Animation.HandDragAnimate exposing
    ( Config
    , HandDragAnimateAction(..)
    , Outcome(..)
    , State
    , dragInfo
    , measurementReceived
    , start
    , step
    )

{-| The hand-drag sub-state-machine for Instant Replay.

Hand-drag animation has three stages, all owned here:

  - **NotYetMeasured** — just constructed by the caller. The
    next `step` produces the DOM-measurement Cmd (using the
    host-supplied `Config`) and advances to
    `AwaitingMeasurement` so subsequent ticks don't refire.
  - **AwaitingMeasurement** — request is in flight. `step`
    is idle here. `measurementReceived` consumes the
    response and transitions to `InFlight`.
  - **InFlight** — the path is being interpolated; each
    `step` advances the floater. `Done` fires when the
    path's duration has elapsed and folds the action into
    the supplied `gameState` directly via `Execute.mergeHand`
    or `Execute.placeHand`.

Same shape for `MergeHand` and `PlaceHand` — the merge-vs-
place distinction matters at landing time and at destination
computation; the in-flight visual is identical.

The state machine is intentionally GameEvent-free: callers
convert their own event payloads into a
`HandDragAnimateAction` at start time, and we own the action
through to its application. The shape uses `targetStack`
(parallel to `BoardDragAnimateAction.Merge`) to normalize
the GameEvent's `target` field name at the conversion
boundary.

The host passes a `Config msg` carrying its `gameId` (for
the board's DOM id) and the `Msg` constructor that should
fire when the measurement Task resolves. The Cmd is built
here so callers don't have to translate "I need
measurement" signals into Cmds themselves.

-}

import Browser.Dom
import Lib.BoardActions as BoardActions exposing (Side)
import Lib.BoardView as BoardView
import Lib.CardStack as CardStack exposing (BoardLocation, CardStack)
import Lib.Execute as Execute
import Lib.Game exposing (GameState)
import Lib.HandDragTypes exposing (HandCardDragInfo)
import Lib.HandLayout as HandLayout
import Lib.Physics.BoardGeometry as BG
import Lib.Physics.GestureArbitration as GA
import Lib.Point exposing (Point)
import Lib.Rules.Card exposing (Card)
import Lib.TimeLoc exposing (TimeLoc)
import Task
import Time


type HandDragAnimateAction
    = MergeHand
        { handCard : Card
        , targetStack : CardStack
        , side : Side
        }
    | PlaceHand
        { handCard : Card
        , loc : BoardLocation
        }


type alias InFlightData =
    { path : List TimeLoc
    , startMs : Int
    , pendingAction : HandDragAnimateAction
    , dragInfo_ : HandCardDragInfo
    }


type State
    = NotYetMeasured HandDragAnimateAction
    | AwaitingMeasurement HandDragAnimateAction
    | InFlight InFlightData


type Outcome
    = InProgress State
    | Done { newGameState : GameState }


type alias Config msg =
    { measureMsg : Result Browser.Dom.Error ( Browser.Dom.Element, Browser.Dom.Element, Time.Posix ) -> msg
    , gameId : String
    }


start : HandDragAnimateAction -> State
start action =
    NotYetMeasured action


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
        AwaitingMeasurement action ->
            let
                origin =
                    elementTopLeftInViewport handElement

                boardRect =
                    boardRectFromElement boardElement
            in
            InFlight (buildInFlight action origin boardRect nowMs)

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


step : Config msg -> Int -> GameState -> State -> ( Outcome, Cmd msg )
step config nowMs gameState state =
    case state of
        NotYetMeasured action ->
            -- First tick after pop. Build the measurement
            -- Cmd and advance the substate so subsequent
            -- ticks see AwaitingMeasurement and idle out.
            let
                card =
                    case action of
                        MergeHand p ->
                            p.handCard

                        PlaceHand p ->
                            p.handCard
            in
            ( InProgress (AwaitingMeasurement action)
            , measurementCmd config card
            )

        AwaitingMeasurement _ ->
            -- Idle; the host's measurement Cmd is in flight.
            ( InProgress state, Cmd.none )

        InFlight d ->
            let
                elapsedMs =
                    nowMs - d.startMs
            in
            if elapsedMs >= duration d.path then
                ( Done { newGameState = applyHandAction d.pendingAction gameState }
                , Cmd.none
                )

            else
                let
                    p =
                        interp d.path elapsedMs

                    info =
                        d.dragInfo_
                in
                ( InProgress
                    (InFlight
                        { d | dragInfo_ = { info | floaterTopLeft = p, cursor = p } }
                    )
                , Cmd.none
                )


{-| Apply the pending hand action to the game state. Dispatches
on the variant to call the right `Execute` op directly, without
going through the `GameEvent` envelope.
-}
applyHandAction : HandDragAnimateAction -> GameState -> GameState
applyHandAction action gameState =
    case action of
        MergeHand p ->
            Execute.mergeHand p.handCard p.targetStack p.side gameState

        PlaceHand p ->
            Execute.placeHand p.handCard p.loc gameState


{-| Bundle the hand card's live rect, the board's live rect,
and the current time into one Task. Same-tick fetching keeps
hand origin and board destination from desyncing across a
page scroll between actions.
-}
measurementCmd : Config msg -> Card -> Cmd msg
measurementCmd config card =
    Task.attempt config.measureMsg
        (Task.map3 (\h b t -> ( h, b, t ))
            (Browser.Dom.getElement (HandLayout.handCardDomId card))
            (Browser.Dom.getElement (BoardView.boardDomIdFor config.gameId))
            Time.now
        )



-- IN-FLIGHT CONSTRUCTION


{-| Synthesize the linear path + initial drag info for a
popped hand action. Dispatches by variant to compute the
floater's destination in viewport coords, then composes
`linearPath` + a fresh `HandCardDragInfo`.
-}
buildInFlight : HandDragAnimateAction -> Point -> GA.Rect -> Int -> InFlightData
buildInFlight action origin boardRect nowMs =
    case action of
        MergeHand p ->
            let
                size =
                    CardStack.size p.targetStack

                landingLeft =
                    case p.side of
                        BoardActions.Right ->
                            p.targetStack.loc.left + size * BG.cardPitch

                        BoardActions.Left ->
                            p.targetStack.loc.left - BG.cardPitch
            in
            inFlightFor
                { handCard = p.handCard
                , origin = origin
                , destination =
                    { x = boardRect.x + landingLeft
                    , y = boardRect.y + p.targetStack.loc.top
                    }
                , startMs = nowMs
                , pendingAction = action
                }

        PlaceHand p ->
            inFlightFor
                { handCard = p.handCard
                , origin = origin
                , destination =
                    { x = boardRect.x + p.loc.left
                    , y = boardRect.y + p.loc.top
                    }
                , startMs = nowMs
                , pendingAction = action
                }


inFlightFor :
    { handCard : Card
    , origin : Point
    , destination : Point
    , startMs : Int
    , pendingAction : HandDragAnimateAction
    }
    -> InFlightData
inFlightFor { handCard, origin, destination, startMs, pendingAction } =
    { path = linearPath origin destination startMs
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


duration : List TimeLoc -> Int
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
linearPath : Point -> Point -> Int -> List TimeLoc
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
            { tMs = startMs + floor (frac * totalMs)
            , left = round (toFloat start_.x + dx * frac)
            , top = round (toFloat start_.y + dy * frac)
            }
    in
    List.range 0 (samples - 1) |> List.map sample


interp : List TimeLoc -> Int -> Point
interp path elapsedMs =
    case path of
        [] ->
            { x = 0, y = 0 }

        first :: _ ->
            interpHelp first path (first.tMs + elapsedMs)


interpHelp : TimeLoc -> List TimeLoc -> Int -> Point
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
                            clamp 0 1 (toFloat (targetTs - prev.tMs) / toFloat (curr.tMs - prev.tMs))
                    in
                    { x = round (toFloat prev.left + frac * toFloat (curr.left - prev.left))
                    , y = round (toFloat prev.top + frac * toFloat (curr.top - prev.top))
                    }

            else
                interpHelp curr rest targetTs
