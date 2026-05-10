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
    `StillReplaying`, `NeedHandCardRect` (host fires a DOM
    query), or `Completed`.

The host feeds DOM measurements back via a small phase-shape
helper of its own (`Main.Play.installHandMeasurement`) that
calls into `HandDragAnimate.measurementReceived` — that path
is shape-work, not engine logic, so it doesn't live here.

`tick` is the workhorse; the only function it delegates to
inside `Animate` is `startNextAction`, which decides what
phase a popped action becomes (real computation). Real
handoffs outside `Animate` are to `BoardDragAnimate` /
`HandDragAnimate` (path interpolation + measurement) and
`Execute.applyEvent` (the apply layer).

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent
import Game.Replay.BoardDragAnimate as BoardDragAnimate
import Game.Replay.HandDragAnimate as HandDragAnimate
import Game.Replay.ReplayState exposing (Phase(..), ReplayState)
import Game.Rules.Card exposing (Card)


{-| Per-step beat in milliseconds. The user wants enough time
to register each teleport / animation landing before the
next one lands.
-}
beatMs : Int
beatMs =
    1500


type TickResult
    = StillReplaying ReplayState
    | NeedHandCardRect ReplayState Card
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
            -- arm a fresh deadline. Other phases freeze in
            -- place.
            case rs.phase of
                InBeat _ ->
                    Starting

                _ ->
                    rs.phase
    in
    { rs | paused = not rs.paused, phase = nextPhase }


tick : Int -> ReplayState -> TickResult
tick nowMs rs =
    case rs.phase of
        Starting ->
            StillReplaying { rs | phase = InBeat { nextBeatMs = nowMs + beatMs } }

        InBeat { nextBeatMs } ->
            if nowMs < nextBeatMs then
                StillReplaying rs

            else
                case rs.queue of
                    [] ->
                        Completed

                    entry :: rest ->
                        let
                            dispatched =
                                startNextAction nowMs entry rs.gameState
                        in
                        StillReplaying
                            { rs
                                | queue = rest
                                , gameState = dispatched.gameState
                                , phase = dispatched.phase
                            }

        ActionCompleted ->
            StillReplaying { rs | phase = InBeat { nextBeatMs = nowMs + beatMs } }

        AnimatingBoardAction dragState ->
            case BoardDragAnimate.step nowMs rs.gameState dragState of
                BoardDragAnimate.InProgress nextDragState ->
                    StillReplaying { rs | phase = AnimatingBoardAction nextDragState }

                BoardDragAnimate.Done { newGameState } ->
                    StillReplaying { rs | gameState = newGameState, phase = ActionCompleted }

        AnimatingHandAction handState ->
            case HandDragAnimate.step nowMs rs.gameState handState of
                HandDragAnimate.InProgress nextHandState ->
                    StillReplaying { rs | phase = AnimatingHandAction nextHandState }

                HandDragAnimate.NeedsMeasurement nextHandState card ->
                    NeedHandCardRect { rs | phase = AnimatingHandAction nextHandState } card

                HandDragAnimate.Done { newGameState } ->
                    StillReplaying { rs | gameState = newGameState, phase = ActionCompleted }


{-| Decide what to do for the popped `entry`: either start
an animation phase (drag events) or apply the event inline
(instant events). For drag events the sub-machine eventually
applies the action itself when its path completes; for
instant events we apply here and slate `ActionCompleted` so
the next tick schedules the beat.

The signature accepts and returns `gameState` because
instant-apply branches need to fold into it; drag branches
echo it back unchanged.

`Undo` is unreachable — `collapseUndos` strips them at the
top of replay.

-}
startNextAction :
    Int
    -> ActionLogEntry
    -> GameState
    ->
        { gameState : GameState
        , phase : Phase
        }
startNextAction nowMs entry gameState =
    case entry.action of
        GameEvent.MergeStack p ->
            { gameState = gameState
            , phase =
                AnimatingBoardAction
                    (BoardDragAnimate.start
                        { sourceStack = p.source
                        , path = p.boardPath
                        , startMs = nowMs
                        , pendingAction = entry.action
                        }
                    )
            }

        GameEvent.MoveStack p ->
            { gameState = gameState
            , phase =
                AnimatingBoardAction
                    (BoardDragAnimate.start
                        { sourceStack = p.stack
                        , path = p.boardPath
                        , startMs = nowMs
                        , pendingAction = entry.action
                        }
                    )
            }

        GameEvent.MergeHand _ ->
            { gameState = gameState
            , phase = AnimatingHandAction (HandDragAnimate.start entry)
            }

        GameEvent.PlaceHand _ ->
            { gameState = gameState
            , phase = AnimatingHandAction (HandDragAnimate.start entry)
            }

        GameEvent.Split _ ->
            { gameState = Execute.applyEvent entry.action gameState
            , phase = ActionCompleted
            }

        GameEvent.CompleteTurn ->
            { gameState = Execute.applyEvent entry.action gameState
            , phase = ActionCompleted
            }

        GameEvent.Undo ->
            Debug.todo
                "Animate.startNextAction: Undo reached the queue (collapseUndos should have stripped it)"
