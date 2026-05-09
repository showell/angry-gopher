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
  - `togglePause rs` — flip `paused`, reset `nextBeatMs` so
    resumption gives a fresh full beat from the next frame.
  - `tick nowMs rs` — one animation-frame step. Returns
    `StillReplaying rs2` when more work remains, or
    `Completed` when the queue empties. The host responds
    to `Completed` by clearing `Model.replayState` (and
    showing the completion ceremony); the engine never
    reaches up into the Model itself.

`nextBeatMs = 0` is the sentinel for "arm on next frame" —
used at start and at resume so the first beat after either
event is a clean `beatMs` gap. Storing absolute deadlines
(rather than counters) means `tick` is correct even if frames
are dropped.

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.Replay.ReplayState exposing (ReplayState)


{-| Per-step beat in milliseconds. The user wants enough time
to register each teleport before the next one lands.
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
    , nextBeatMs = 0
    }


togglePause : ReplayState -> ReplayState
togglePause rs =
    { rs | paused = not rs.paused, nextBeatMs = 0 }


tick : Int -> ReplayState -> TickResult
tick nowMs rs =
    if rs.nextBeatMs == 0 then
        StillReplaying (armBeat nowMs rs)

    else if nowMs < rs.nextBeatMs then
        StillReplaying rs

    else
        stepOne nowMs rs


{-| The work of advancing one frame past the deadline: pop
the next entry, fold it into `gameState`, re-arm the beat.
Returns `Completed` if the queue was already drained.
-}
stepOne : Int -> ReplayState -> TickResult
stepOne nowMs rs =
    case rs.queue of
        [] ->
            Completed

        entry :: rest ->
            { rs | queue = rest }
                |> applyEntry entry
                |> armBeat nowMs
                |> StillReplaying


applyEntry : ActionLogEntry -> ReplayState -> ReplayState
applyEntry entry rs =
    { rs | gameState = Execute.applyEvent entry.action rs.gameState }


armBeat : Int -> ReplayState -> ReplayState
armBeat nowMs rs =
    { rs | nextBeatMs = nowMs + beatMs }
