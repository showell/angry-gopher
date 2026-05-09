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
    replay. Caller passes an already-collapsed queue
    (`ActionLog.collapseUndos`); replay never sees an `Undo`.
  - `togglePause rs` — flip `paused`. When the replay was
    InBeat, transition to `Starting` so resumption gets a
    fresh full beat from the next frame.
  - `tick nowMs rs` — one animation-frame step. Returns
    `StillReplaying rs2` when more work remains, or
    `Completed` when the queue empties. The host responds
    to `Completed` by clearing `Model.replayState` (and
    showing the completion ceremony); the engine never
    reaches up into the Model itself.

`tick` dispatches by phase and delegates the bulk of each
phase's processing to its own helper. The two real handoffs
are to `BoardDragAnimate` (path interpolation) and
`Execute.applyEvent` (the apply layer).

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent
import Game.Replay.BoardDragAnimate as BoardDragAnimate
import Game.Replay.ReplayState exposing (Phase(..), ReplayState)


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
    , phase = Starting
    }


togglePause : ReplayState -> ReplayState
togglePause rs =
    let
        nextPhase =
            -- An InBeat deadline is computed from a `nowMs` we
            -- can't see at click time, so we fall back to
            -- Starting and let the first frame after resume
            -- arm a fresh deadline. Animating freezes in place;
            -- Starting stays Starting.
            case rs.phase of
                InBeat _ ->
                    Starting

                _ ->
                    rs.phase
    in
    { rs | paused = not rs.paused, phase = nextPhase }


tick : Int -> ReplayState -> TickResult
tick nowMs rs =
    let
        nextBeat =
            nowMs + beatMs
    in
    case rs.phase of
        Starting ->
            StillReplaying { rs | phase = InBeat { nextBeatMs = nextBeat } }

        InBeat { nextBeatMs } ->
            tickInBeat nowMs nextBeat nextBeatMs rs

        Animating dragState ->
            tickInAnimation nowMs nextBeat dragState rs


{-| InBeat: hold until `nowMs` hits the deadline, then pop
the next entry and dispatch by event variant. MergeStack /
MoveStack open a board-drag animation; the rest teleport via
`Execute.applyEvent` and re-enter InBeat. Empty queue =>
`Completed`.
-}
tickInBeat : Int -> Int -> Int -> ReplayState -> TickResult
tickInBeat nowMs nextBeat nextBeatMs rs =
    if nowMs < nextBeatMs then
        StillReplaying rs

    else
        case rs.queue of
            [] ->
                Completed

            entry :: rest ->
                let
                    rsPopped =
                        { rs | queue = rest }
                in
                case entry.action of
                    GameEvent.MergeStack p ->
                        StillReplaying
                            { rsPopped
                                | phase =
                                    Animating
                                        (BoardDragAnimate.start
                                            { sourceStack = p.source
                                            , path = p.boardPath
                                            , startMs = nowMs
                                            , pendingAction = entry.action
                                            }
                                        )
                            }

                    GameEvent.MoveStack p ->
                        StillReplaying
                            { rsPopped
                                | phase =
                                    Animating
                                        (BoardDragAnimate.start
                                            { sourceStack = p.stack
                                            , path = p.boardPath
                                            , startMs = nowMs
                                            , pendingAction = entry.action
                                            }
                                        )
                            }

                    GameEvent.Split _ ->
                        StillReplaying
                            { rsPopped
                                | gameState = Execute.applyEvent entry.action rs.gameState
                                , phase = InBeat { nextBeatMs = nextBeat }
                            }

                    GameEvent.MergeHand _ ->
                        StillReplaying
                            { rsPopped
                                | gameState = Execute.applyEvent entry.action rs.gameState
                                , phase = InBeat { nextBeatMs = nextBeat }
                            }

                    GameEvent.PlaceHand _ ->
                        StillReplaying
                            { rsPopped
                                | gameState = Execute.applyEvent entry.action rs.gameState
                                , phase = InBeat { nextBeatMs = nextBeat }
                            }

                    GameEvent.CompleteTurn ->
                        StillReplaying
                            { rsPopped
                                | gameState = Execute.applyEvent entry.action rs.gameState
                                , phase = InBeat { nextBeatMs = nextBeat }
                            }

                    GameEvent.Undo ->
                        Debug.todo
                            "Animate.tickInBeat: Undo reached the queue (collapseUndos should have stripped it)"


{-| Animating: hand the frame to the sub-machine. On
`InProgress`, swap in its updated state. On `Done`, apply
the pending action and re-enter InBeat with a fresh
deadline so the user sees the landed result.
-}
tickInAnimation : Int -> Int -> BoardDragAnimate.State -> ReplayState -> TickResult
tickInAnimation nowMs nextBeat dragState rs =
    case BoardDragAnimate.step nowMs dragState of
        BoardDragAnimate.InProgress nextDragState ->
            StillReplaying { rs | phase = Animating nextDragState }

        BoardDragAnimate.Done { pendingAction } ->
            StillReplaying
                { rs
                    | gameState = Execute.applyEvent pendingAction rs.gameState
                    , phase = InBeat { nextBeatMs = nextBeat }
                }
