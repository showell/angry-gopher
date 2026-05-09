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
    `Completed` when the queue empties.

`tick` is the workhorse; it dispatches by phase and handles
each case inline. The variant-by-variant decision of "what
phase do we enter for this action" is delegated to
`startNextAction` — that's the only real handoff inside
`Animate`, because the decision IS the computation. Other
handoffs are to `BoardDragAnimate` (path interpolation) and
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
    let
        nextBeat =
            nowMs + beatMs
    in
    case rs.phase of
        Starting ->
            StillReplaying { rs | phase = InBeat { nextBeatMs = nextBeat } }

        InBeat { nextBeatMs } ->
            if nowMs < nextBeatMs then
                StillReplaying rs

            else
                case rs.queue of
                    [] ->
                        Completed

                    entry :: rest ->
                        StillReplaying
                            { rs
                                | queue = rest
                                , phase = startNextAction nowMs entry
                            }

        ExecutingAction entry ->
            StillReplaying
                { rs
                    | gameState = Execute.applyEvent entry.action rs.gameState
                    , phase = InBeat { nextBeatMs = nextBeat }
                }

        AnimatingAction dragState ->
            case BoardDragAnimate.step nowMs dragState of
                BoardDragAnimate.InProgress nextDragState ->
                    StillReplaying { rs | phase = AnimatingAction nextDragState }

                BoardDragAnimate.Done { pendingAction } ->
                    StillReplaying
                        { rs
                            | gameState = Execute.applyEvent pendingAction rs.gameState
                            , phase = InBeat { nextBeatMs = nextBeat }
                        }


{-| Decide which phase to enter when popping `entry` off the
queue. Board-drag events open an `AnimatingAction` (with the
sub-machine pre-built); everything else slates an
`ExecutingAction` for the next tick to apply. The extra tick
between pop and apply costs ~16ms inside a 1500ms beat — no
perceptual difference, but it gives every action variant a
uniform "what do I become" answer.

`Undo` is unreachable — `collapseUndos` strips them at the
top of replay.

-}
startNextAction : Int -> ActionLogEntry -> Phase
startNextAction nowMs entry =
    case entry.action of
        GameEvent.MergeStack p ->
            AnimatingAction
                (BoardDragAnimate.start
                    { sourceStack = p.source
                    , path = p.boardPath
                    , startMs = nowMs
                    , pendingAction = entry.action
                    }
                )

        GameEvent.MoveStack p ->
            AnimatingAction
                (BoardDragAnimate.start
                    { sourceStack = p.stack
                    , path = p.boardPath
                    , startMs = nowMs
                    , pendingAction = entry.action
                    }
                )

        GameEvent.Split _ ->
            ExecutingAction entry

        GameEvent.MergeHand _ ->
            ExecutingAction entry

        GameEvent.PlaceHand _ ->
            ExecutingAction entry

        GameEvent.CompleteTurn ->
            ExecutingAction entry

        GameEvent.Undo ->
            Debug.todo
                "Animate.startNextAction: Undo reached the queue (collapseUndos should have stripped it)"
