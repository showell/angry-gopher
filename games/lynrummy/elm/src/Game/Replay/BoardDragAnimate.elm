module Game.Replay.BoardDragAnimate exposing
    ( Outcome(..)
    , State
    , start
    , step
    )

{-| The board-drag sub-state-machine for Instant Replay.

Same animation shape for `MergeStack` and `MoveStack` — the
floater flies along a captured path; the merge-vs-move
distinction only matters at landing time, which is the outer
machine's job (apply via `Execute.applyEvent`).

The path is mandatory and arrives intact in the event's
payload. We own every caller (Elm gestures, TS agent
transcript writer, Go server, conformance fixtures), so an
empty `path` is a contract violation, not a thing to handle.

-}

import Game.BoardDragTypes exposing (BoardCardDragInfo)
import Game.CardStack exposing (CardStack)
import Game.GameEvent exposing (GameEvent)
import Game.Point exposing (Point)
import Game.TimeLoc exposing (TimeLoc)


type alias State =
    { path : List TimeLoc
    , startMs : Int
    , pendingAction : GameEvent
    , dragInfo : BoardCardDragInfo
    }


type Outcome
    = InProgress State
    | Done { pendingAction : GameEvent }


start :
    { sourceStack : CardStack
    , path : List TimeLoc
    , startMs : Int
    , pendingAction : GameEvent
    }
    -> State
start { sourceStack, path, startMs, pendingAction } =
    case path of
        [] ->
            -- Caller contract violated: every board-drag event
            -- carries a non-empty boardPath in its payload.
            Debug.todo
                "BoardDragAnimate.start: empty path — caller must provide a path"

        first :: _ ->
            { path = path
            , startMs = startMs
            , pendingAction = pendingAction
            , dragInfo =
                { stack = sourceStack
                , cardIndex = 0
                , originalCursor = { x = 0, y = 0 }
                , cursor = { x = 0, y = 0 }
                , floaterTopLeft = { left = first.left, top = first.top }
                , boardPath = path
                , wings = []
                }
            }


{-| Advance one frame. Returns `Done` once `nowMs - startMs`
exceeds the path's total duration, otherwise updates the
floater's position via linear interpolation.
-}
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


setFloater : Point -> BoardCardDragInfo -> BoardCardDragInfo
setFloater p info =
    { info | floaterTopLeft = { left = p.x, top = p.y } }


duration : List TimeLoc -> Float
duration path =
    case ( List.head path, List.head (List.reverse path) ) of
        ( Just first, Just last ) ->
            last.tMs - first.tMs

        _ ->
            0


{-| Linear-interpolate cursor position along the path.
Caller has already gated on `elapsedMs < duration path`, so
the path is non-empty and the elapsed time falls inside it.
-}
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
