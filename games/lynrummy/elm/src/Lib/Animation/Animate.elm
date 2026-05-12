module Lib.Animation.Animate exposing
    ( Phase(..)
    , AnimationState
    , TickResult(..)
    , start
    , tick
    , togglePause
    )

{-| The Instant Replay state machine. Mostly pure data
transforms on `AnimationState`; the only side-effect surface
is the measurement Cmd produced by `HandDragAnimate.step`,
which `tick` forwards back to the host alongside its
state result.

Three operations the host (`Main.Play`) plumbs through:

  - `start initialEntries initialGameState` — open a fresh
    replay. Caller passes an already-collapsed queue
    (`ActionLog.collapseUndos`); replay never sees an `Undo`.
  - `togglePause rs` — flip `paused`. When the replay was
    InBeat, transition to `Starting` so resumption gets a
    fresh full beat from the next frame.
  - `tick config nowMs rs` — one animation-frame step.
    Returns `StillReplaying nextRs cmd` (with `Cmd.none`
    most ticks; the measurement Cmd on the first frame
    after a hand action pops) or `Completed`.

The host feeds DOM measurements back via a small phase-shape
helper of its own (`Main.Play.installHandMeasurement`) that
calls into `HandDragAnimate.measurementReceived`.

-}

import Lib.ActionLog exposing (ActionLogEntry)
import Lib.Execute as Execute
import Lib.Game as Game exposing (GameState)
import Lib.GameEvent as GameEvent
import Lib.Physics.BoardGeometry exposing (refereeBounds)
import Lib.Animation.BoardDragAnimate as BoardDragAnimate
import Lib.Animation.HandDragAnimate as HandDragAnimate


{-| Replay's five phases. Each tick reads `phase`, does its
phase-appropriate work, and transitions accordingly.

  - `Starting` — pre-arm. The clock hasn't been seen yet;
    the first frame to arrive sets the next beat deadline.
    Used at replay click and on resume-from-pause so each
    gives a fresh full beat.
  - `InBeat` — holding between actions. `nextBeatMs` is the
    absolute deadline at which the next entry pops.
  - `ActionCompleted` — transient (one tick): an action has
    just been applied (either inline by `startNextAction`
    for instant-apply events, or by a sub-machine's `Done`
    outcome for animated events). The next tick schedules
    the inter-action beat and transitions to `InBeat`.
  - `AnimatingBoardAction` — a board-drag animation is in
    flight. The sub-machine applies its event and signals
    `Done` when the path completes.
  - `AnimatingHandAction` — a hand-drag animation is in
    flight. Same shape as the board side; the sub-state
    owns the NotYetMeasured / AwaitingMeasurement / InFlight
    distinctions internally.

-}
type Phase
    = Starting
    | InBeat { nextBeatMs : Int }
    | ActionCompleted
    | AnimatingBoardAction BoardDragAnimate.State
    | AnimatingHandAction HandDragAnimate.State


{-| Instant Replay's working state. Lives on `Main.State.Model`
as `Maybe AnimationState`: `Just _` while a replay is in flight,
`Nothing` otherwise.

The View reads `gameState` (to render the replay's evolving
board + sidebar), `paused` (to pick the Pause/Resume button
label), and inspects `phase` to source the drag floater
during board-drag and hand-drag animations. All other fields
are private to this module.

-}
type alias AnimationState =
    { queue : List ActionLogEntry
    , gameState : GameState
    , paused : Bool
    , phase : Phase
    }


type TickResult msg
    = StillReplaying AnimationState (Cmd msg)
    | Completed


{-| Per-step beat in milliseconds. The user wants enough time
to register each teleport / animation landing before the
next one lands.
-}
beatMs : Int
beatMs =
    700


start : List ActionLogEntry -> GameState -> AnimationState
start queue gameState =
    { queue = queue
    , gameState = gameState
    , paused = False
    , phase = Starting
    }


togglePause : AnimationState -> AnimationState
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


tick : HandDragAnimate.Config msg -> Int -> AnimationState -> TickResult msg
tick config nowMs rs =
    case rs.phase of
        Starting ->
            StillReplaying { rs | phase = InBeat { nextBeatMs = nowMs + beatMs } } Cmd.none

        InBeat { nextBeatMs } ->
            if nowMs < nextBeatMs then
                StillReplaying rs Cmd.none

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
                            Cmd.none

        ActionCompleted ->
            StillReplaying { rs | phase = InBeat { nextBeatMs = nowMs + beatMs } } Cmd.none

        AnimatingBoardAction dragState ->
            case BoardDragAnimate.step nowMs rs.gameState.board dragState of
                BoardDragAnimate.InProgress nextDragState ->
                    StillReplaying { rs | phase = AnimatingBoardAction nextDragState } Cmd.none

                BoardDragAnimate.Done { newBoard } ->
                    let
                        gs0 =
                            rs.gameState
                    in
                    StillReplaying
                        { rs
                            | gameState = { gs0 | board = newBoard }
                            , phase = ActionCompleted
                        }
                        Cmd.none

        AnimatingHandAction handState ->
            case HandDragAnimate.step config nowMs rs.gameState handState of
                ( HandDragAnimate.InProgress nextHandState, cmd ) ->
                    StillReplaying { rs | phase = AnimatingHandAction nextHandState } cmd

                ( HandDragAnimate.Done { newGameState }, _ ) ->
                    StillReplaying { rs | gameState = newGameState, phase = ActionCompleted } Cmd.none


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
                        { startMs = nowMs
                        , pendingAction =
                            BoardDragAnimate.Merge
                                { sourceStack = p.source
                                , targetStack = p.target
                                , side = p.side
                                , boardPath = p.boardPath
                                }
                        }
                    )
            }

        GameEvent.MoveStack p ->
            { gameState = gameState
            , phase =
                AnimatingBoardAction
                    (BoardDragAnimate.start
                        { startMs = nowMs
                        , pendingAction =
                            BoardDragAnimate.Move
                                { sourceStack = p.stack
                                , newLoc = p.newLoc
                                , boardPath = p.boardPath
                                }
                        }
                    )
            }

        GameEvent.MergeHand p ->
            { gameState = gameState
            , phase =
                AnimatingHandAction
                    (HandDragAnimate.start
                        (HandDragAnimate.MergeHand
                            { handCard = p.handCard
                            , targetStack = p.target
                            , side = p.side
                            }
                        )
                    )
            }

        GameEvent.PlaceHand p ->
            { gameState = gameState
            , phase =
                AnimatingHandAction
                    (HandDragAnimate.start
                        (HandDragAnimate.PlaceHand
                            { handCard = p.handCard
                            , loc = p.loc
                            }
                        )
                    )
            }

        GameEvent.Split p ->
            { gameState =
                { gameState | board = Execute.split p.stack p.cardIndex gameState.board }
            , phase = ActionCompleted
            }

        GameEvent.CompleteTurn ->
            { gameState = Tuple.first (Game.applyCompleteTurn refereeBounds gameState)
            , phase = ActionCompleted
            }

        GameEvent.Undo ->
            Debug.todo
                "Animate.startNextAction: Undo reached the queue (collapseUndos should have stripped it)"
