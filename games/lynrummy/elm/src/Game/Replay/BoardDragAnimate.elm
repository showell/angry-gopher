module Game.Replay.BoardDragAnimate exposing
    ( BoardDragAnimateAction(..)
    , Outcome(..)
    , State
    , start
    , step
    )

{-| The board-drag sub-state-machine for Instant Replay.

Same animation shape for stack-merge and stack-move — the
floater flies along a captured path; the merge-vs-move
distinction matters only at landing time, where this module
calls `Execute.mergeStack` / `Execute.moveStack` directly.

The state machine is intentionally GameEvent-free: callers
convert their own event payloads into a
`BoardDragAnimateAction` at start time (where they have the
earned knowledge of which variant they're dealing with),
and we then own the action through to its application. The
shape uses `sourceStack` consistently across both variants —
the asymmetric `source` / `stack` field names from
`Game.GameEvent` get normalized at the conversion boundary.

-}

import Game.BoardActions exposing (Side)
import Game.BoardDragTypes exposing (BoardCardDragInfo)
import Game.CardStack exposing (BoardLocation, CardStack)
import Game.Execute as Execute
import Game.Point exposing (Point)
import Game.TimeLoc exposing (TimeLoc)


type BoardDragAnimateAction
    = Move
        { sourceStack : CardStack
        , newLoc : BoardLocation
        , boardPath : List TimeLoc
        }
    | Merge
        { sourceStack : CardStack
        , targetStack : CardStack
        , side : Side
        , boardPath : List TimeLoc
        }


type alias State =
    { path : List TimeLoc
    , startMs : Int
    , pendingAction : BoardDragAnimateAction
    , dragInfo : BoardCardDragInfo
    }


type Outcome
    = InProgress State
    | Done { newBoard : List CardStack }


start : { startMs : Int, pendingAction : BoardDragAnimateAction } -> State
start { startMs, pendingAction } =
    let
        ( sourceStack, path ) =
            case pendingAction of
                Move m ->
                    ( m.sourceStack, m.boardPath )

                Merge m ->
                    ( m.sourceStack, m.boardPath )
    in
    case path of
        [] ->
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


{-| Advance one frame. Once `nowMs - startMs` exceeds the
path's total duration, dispatch on the pending action's
variant and call the right `Execute` board operation
directly. The apply lives here (rather than in the outer
machine) so the sub-machine fully owns the action it was
started for.

The sub-machine deliberately operates on `List CardStack`
rather than the full `GameState` — the board is everything
a stack-move/merge animation cares about. The outer machine
plugs the returned board back into its game state.

-}
step : Int -> List CardStack -> State -> Outcome
step nowMs board state =
    let
        elapsedMs =
            nowMs - state.startMs
    in
    if elapsedMs >= duration state.path then
        Done { newBoard = applyToBoard state.pendingAction board }

    else
        let
            p =
                interp state.path elapsedMs

            info =
                state.dragInfo
        in
        InProgress
            { state
                | dragInfo = { info | floaterTopLeft = { left = p.x, top = p.y } }
            }


{-| Apply the pending board action to the board. Dispatches
on the variant to call the right `Execute` operation
directly — no GameEvent in sight.
-}
applyToBoard : BoardDragAnimateAction -> List CardStack -> List CardStack
applyToBoard action board =
    case action of
        Move m ->
            Execute.moveStack m.sourceStack m.newLoc board

        Merge m ->
            Execute.mergeStack m.sourceStack m.targetStack m.side board


duration : List TimeLoc -> Int
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
