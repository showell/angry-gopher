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

`tick` is the workhorse: dispatch on phase → if Beat, dispatch
on time → if armed and overdue, pop the queue → dispatch on
event variant. The only real handoffs are to
`BoardDragAnimate` (path interpolation — a real computation)
and `Execute.applyEvent` (the apply layer). Everything else
stays inline so the case ladder reads top-to-bottom.

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
            if nextBeatMs == 0 then
                StillReplaying { rs | phase = Beat { nextBeatMs = nowMs + beatMs } }

            else if nowMs < nextBeatMs then
                StillReplaying rs

            else
                case rs.queue of
                    [] ->
                        Completed

                    entry :: rest ->
                        let
                            rsPopped =
                                { rs | queue = rest }

                            nextBeat =
                                nowMs + beatMs
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
                                        , phase = Beat { nextBeatMs = nextBeat }
                                    }

                            GameEvent.MergeHand _ ->
                                StillReplaying
                                    { rsPopped
                                        | gameState = Execute.applyEvent entry.action rs.gameState
                                        , phase = Beat { nextBeatMs = nextBeat }
                                    }

                            GameEvent.PlaceHand _ ->
                                StillReplaying
                                    { rsPopped
                                        | gameState = Execute.applyEvent entry.action rs.gameState
                                        , phase = Beat { nextBeatMs = nextBeat }
                                    }

                            GameEvent.CompleteTurn ->
                                StillReplaying
                                    { rsPopped
                                        | gameState = Execute.applyEvent entry.action rs.gameState
                                        , phase = Beat { nextBeatMs = nextBeat }
                                    }

                            GameEvent.Undo ->
                                Debug.todo
                                    "Animate.tick: Undo reached the queue (collapseUndos should have stripped it)"

        Animating dragState ->
            case BoardDragAnimate.step nowMs dragState of
                BoardDragAnimate.InProgress nextDragState ->
                    StillReplaying { rs | phase = Animating nextDragState }

                BoardDragAnimate.Done { pendingAction } ->
                    StillReplaying
                        { rs
                            | gameState = Execute.applyEvent pendingAction rs.gameState
                            , phase = Beat { nextBeatMs = nowMs + beatMs }
                        }
