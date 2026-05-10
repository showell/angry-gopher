module Game.Replay.Animate exposing
    ( TickResult(..)
    , handCardRectReceived
    , start
    , tick
    , togglePause
    )

{-| The Instant Replay state machine. Pure data transforms
on `ReplayState`; no Msg types, no Cmd, no Model.

Four operations the host (`Main.Play`) plumbs through:

  - `start initialEntries initialGameState` — open a fresh
    replay. Caller passes an already-collapsed queue
    (`ActionLog.collapseUndos`); replay never sees an `Undo`.
  - `togglePause rs` — flip `paused`. When the replay was
    InBeat, transition to `Starting` so resumption gets a
    fresh full beat from the next frame.
  - `tick nowMs rs` — one animation-frame step. Returns
    `StillReplaying`, `NeedHandCardRect` (host fires a DOM
    query), or `Completed`.
  - `handCardRectReceived nowMs handElement boardElement rs`
    — host calls this when its DOM query resolves; we
    delegate into `HandDragAnimate.measurementReceived` to
    transition the hand sub-machine from awaiting to
    in-flight.

`tick` is the workhorse; the only function it delegates to
inside `Animate` is `startNextAction`, which decides what
phase a popped action becomes (real computation). Real
handoffs outside `Animate` are to `BoardDragAnimate` /
`HandDragAnimate` (path interpolation + measurement) and
`Execute.applyEvent` (the apply layer).

-}

import Browser.Dom
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
                        let
                            ( newPhase, maybeMeasure ) =
                                startNextAction nowMs entry

                            newRs =
                                { rs | queue = rest, phase = newPhase }
                        in
                        case maybeMeasure of
                            Just card ->
                                NeedHandCardRect newRs card

                            Nothing ->
                                StillReplaying newRs

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

        AnimatingHandAction handState ->
            case HandDragAnimate.step nowMs handState of
                HandDragAnimate.InProgress nextHandState ->
                    StillReplaying { rs | phase = AnimatingHandAction nextHandState }

                HandDragAnimate.Done { pendingAction } ->
                    StillReplaying
                        { rs
                            | gameState = Execute.applyEvent pendingAction rs.gameState
                            , phase = InBeat { nextBeatMs = nextBeat }
                        }


{-| Decide what phase to enter when popping `entry` off the
queue, plus optionally name a hand card the host should
DOM-measure. Board-drag events open `AnimatingAction`
immediately. Hand-drag events open `AnimatingHandAction`
with `HandDragAnimate`'s AwaitingMeasurement substate; the
sub-machine answers `measureRequest` so the host knows
which card to query. Everything else slates `ExecutingAction`
for the next tick.

`Undo` is unreachable — `collapseUndos` strips them at the
top of replay.

-}
startNextAction : Int -> ActionLogEntry -> ( Phase, Maybe Card )
startNextAction nowMs entry =
    case entry.action of
        GameEvent.MergeStack p ->
            ( AnimatingAction
                (BoardDragAnimate.start
                    { sourceStack = p.source
                    , path = p.boardPath
                    , startMs = nowMs
                    , pendingAction = entry.action
                    }
                )
            , Nothing
            )

        GameEvent.MoveStack p ->
            ( AnimatingAction
                (BoardDragAnimate.start
                    { sourceStack = p.stack
                    , path = p.boardPath
                    , startMs = nowMs
                    , pendingAction = entry.action
                    }
                )
            , Nothing
            )

        GameEvent.MergeHand _ ->
            let
                handState =
                    HandDragAnimate.start entry
            in
            ( AnimatingHandAction handState, HandDragAnimate.measureRequest handState )

        GameEvent.PlaceHand _ ->
            let
                handState =
                    HandDragAnimate.start entry
            in
            ( AnimatingHandAction handState, HandDragAnimate.measureRequest handState )

        GameEvent.Split _ ->
            ( ExecutingAction entry, Nothing )

        GameEvent.CompleteTurn ->
            ( ExecutingAction entry, Nothing )

        GameEvent.Undo ->
            Debug.todo
                "Animate.startNextAction: Undo reached the queue (collapseUndos should have stripped it)"


{-| Host calls this when its bundled DOM query (hand card +
board element + time) resolves. We thread the elements down
into the `HandDragAnimate` sub-machine, which extracts both
viewport coords, builds the linear path, and transitions
itself from AwaitingMeasurement to InFlight. Animate just
routes — the geometry math lives one level down.
-}
handCardRectReceived :
    Int
    -> Browser.Dom.Element
    -> Browser.Dom.Element
    -> ReplayState
    -> ReplayState
handCardRectReceived nowMs handElement boardElement rs =
    case rs.phase of
        AnimatingHandAction handState ->
            { rs
                | phase =
                    AnimatingHandAction
                        (HandDragAnimate.measurementReceived
                            nowMs
                            handElement
                            boardElement
                            handState
                        )
            }

        _ ->
            -- Wrong phase (rect arrived after we transitioned
            -- away — pause-toggled, replay completed, etc.).
            -- Drop the late result.
            rs
