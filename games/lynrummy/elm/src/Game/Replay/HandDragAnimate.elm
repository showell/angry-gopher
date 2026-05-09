module Game.Replay.HandDragAnimate exposing
    ( Outcome(..)
    , State
    , start
    , step
    )

{-| The hand-drag sub-state-machine for Instant Replay.

Same animation shape for `MergeHand` and `PlaceHand` — the
floater flies from the hand card's live viewport position to
a board destination point. The merge-vs-place distinction
matters at landing time (handled by `Execute.applyEvent` in
the outer machine) and at destination computation (a stack
side vs. an explicit board location, done by the caller
before invoking `start`); the in-flight visual is identical.

Hand drags can't reuse a captured path the way board drags
can — the hand card's viewport position depends on layout +
scroll state at replay time, so the path is synthesized via
`linearPath` from the measured `origin` to the computed
`destination`.

-}

import Game.GameEvent exposing (GameEvent)
import Game.HandDragTypes exposing (HandCardDragInfo)
import Game.Point exposing (Point)
import Game.Rules.Card exposing (Card)
import Game.TimeLoc exposing (TimeLoc)


type alias State =
    { path : List TimeLoc
    , startMs : Int
    , pendingAction : GameEvent
    , dragInfo : HandCardDragInfo
    }


type Outcome
    = InProgress State
    | Done { pendingAction : GameEvent }


start :
    { handCard : Card
    , origin : Point
    , destination : Point
    , startMs : Int
    , pendingAction : GameEvent
    }
    -> State
start { handCard, origin, destination, startMs, pendingAction } =
    { path = linearPath origin destination (toFloat startMs)
    , startMs = startMs
    , pendingAction = pendingAction
    , dragInfo =
        { card = handCard
        , cursor = origin
        , floaterTopLeft = origin
        , wings = []
        }
    }


step : Int -> State -> Outcome
step nowMs state =
    let
        elapsedMs =
            toFloat (nowMs - state.startMs)
    in
    if elapsedMs >= duration state.path then
        Done { pendingAction = state.pendingAction }

    else
        InProgress
            { state
                | dragInfo = setFloater (interp state.path elapsedMs) state.dragInfo
            }


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
