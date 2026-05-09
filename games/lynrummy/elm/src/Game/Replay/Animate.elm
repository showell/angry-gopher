module Game.Replay.Animate exposing
    ( TickResult(..)
    , start
    , tick
    , togglePause
    )

{-| The Instant Replay state machine. Pure data transforms
on `ReplayState`; no Msg types, no Cmd, no Model.

Three operations the host (`Main.Play`) plumbs through:

  - `start initialEntries initialGameState` — open a fresh
    replay. Caller is expected to pass an already-collapsed
    queue (`ActionLog.collapseUndos`); replay never sees an
    `Undo` event.
  - `togglePause rs` — flip `paused`. When in Beat phase,
    also reset the deadline so resumption gives a fresh full
    beat from the next frame.
  - `tick nowMs rs` — one animation-frame step. Returns
    `StillReplaying rs2` when more work remains, or
    `Completed` when the queue empties. The host responds
    to `Completed` by clearing `Model.replayState` (and
    showing the completion ceremony); the engine never
    reaches up into the Model itself.

The `Phase` sum type splits the two cadences:

  - `Beat` is the inter-action wait. The deadline
    (`nextBeatMs = 0` sentinel for "arm on next frame") lets
    the first beat time start from the next animation frame
    regardless of when the click landed.
  - `Animating` delegates per-frame work to
    `Game.Replay.BoardDragAnimate`. When that sub-machine
    signals `Done`, we apply the pending action to
    `gameState` and re-enter `Beat`.

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.CardStack exposing (CardStack)
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.Replay.BoardDragAnimate as BoardDragAnimate
import Game.Replay.ReplayState exposing (Phase(..), ReplayState)
import Game.TimeLoc exposing (TimeLoc)


{-| Per-step beat in milliseconds. The user wants enough time
to register each teleport / animation landing before the
next one lands.
-}
beatMs : Int
beatMs =
    1500


type TickResult
    = StillReplaying ReplayState
    | Completed


start : List ActionLogEntry -> GameState -> ReplayState
start queue gameState =
    { queue = queue
    , gameState = gameState
    , paused = False
    , phase = Beat { nextBeatMs = 0 }
    }


togglePause : ReplayState -> ReplayState
togglePause rs =
    case rs.phase of
        Beat _ ->
            -- Reset the beat deadline so resume gives a fresh
            -- 1.5s gap before the next action pops.
            { rs | paused = not rs.paused, phase = Beat { nextBeatMs = 0 } }

        Animating _ ->
            { rs | paused = not rs.paused }


tick : Int -> ReplayState -> TickResult
tick nowMs rs =
    case rs.phase of
        Beat { nextBeatMs } ->
            tickBeat nowMs nextBeatMs rs

        Animating dragState ->
            tickAnimating nowMs dragState rs


tickBeat : Int -> Int -> ReplayState -> TickResult
tickBeat nowMs nextBeatMs rs =
    if nextBeatMs == 0 then
        StillReplaying { rs | phase = Beat { nextBeatMs = nowMs + beatMs } }

    else if nowMs < nextBeatMs then
        StillReplaying rs

    else
        popAndDispatch nowMs rs


{-| Pop the next entry off the queue and dispatch it: either
into a board-drag animation (MergeStack / MoveStack — they
carry a path), or apply directly and re-enter Beat (everything
else).

`Completed` fires when the queue is already drained.

-}
popAndDispatch : Int -> ReplayState -> TickResult
popAndDispatch nowMs rs =
    case rs.queue of
        [] ->
            Completed

        entry :: rest ->
            case boardDragInputs entry.action of
                Just inputs ->
                    StillReplaying
                        { rs
                            | queue = rest
                            , phase =
                                Animating
                                    (BoardDragAnimate.start
                                        { sourceStack = inputs.sourceStack
                                        , path = inputs.path
                                        , startMs = nowMs
                                        , pendingAction = entry.action
                                        }
                                    )
                        }

                Nothing ->
                    StillReplaying
                        { rs
                            | queue = rest
                            , gameState = Execute.applyEvent entry.action rs.gameState
                            , phase = Beat { nextBeatMs = nowMs + beatMs }
                        }


{-| Returns Just inputs when the event is one of the two
animatable board-drag variants, Nothing otherwise. Asymmetric
field naming (`p.source` vs `p.stack`) is a known quirk of
the GameEvent payloads we don't fix here.
-}
boardDragInputs : GameEvent -> Maybe { sourceStack : CardStack, path : List TimeLoc }
boardDragInputs action =
    case action of
        GameEvent.MergeStack p ->
            Just { sourceStack = p.source, path = p.boardPath }

        GameEvent.MoveStack p ->
            Just { sourceStack = p.stack, path = p.boardPath }

        _ ->
            Nothing


tickAnimating : Int -> BoardDragAnimate.State -> ReplayState -> TickResult
tickAnimating nowMs dragState rs =
    case BoardDragAnimate.step nowMs dragState of
        BoardDragAnimate.InProgress nextDragState ->
            StillReplaying { rs | phase = Animating nextDragState }

        BoardDragAnimate.Done { pendingAction } ->
            StillReplaying
                { rs
                    | gameState = Execute.applyEvent pendingAction rs.gameState
                    , phase = Beat { nextBeatMs = nowMs + beatMs }
                }
