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
  - `handCardRectReceived nowMs element maybeBoardRect rs` —
    host calls this when its DOM query resolves; we transition
    `AwaitingHandRect` → `AnimatingHandAction`.

`tick` is the workhorse; the only function it delegates to
inside `Animate` is `startNextAction`, which decides what
phase a popped action becomes (real computation). Real
handoffs outside `Animate` are to `BoardDragAnimate` /
`HandDragAnimate` (path interpolation) and `Execute.applyEvent`
(the apply layer).

-}

import Browser.Dom
import Game.ActionLog exposing (ActionLogEntry)
import Game.BoardActions as BoardActions
import Game.CardStack as CardStack
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
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

        AwaitingHandRect _ ->
            -- Waiting for the host's DOM query to resolve.
            -- Re-emitting NeedHandCardRect would fire a second
            -- query; the host fires once, on the InBeat→
            -- AwaitingHandRect transition. Just hold.
            StillReplaying rs

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
immediately. Hand-drag events open `AwaitingHandRect` and
ask the host to measure the source hand card. Everything
else slates `ExecutingAction` for the next tick.

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

        GameEvent.MergeHand p ->
            ( AwaitingHandRect entry, Just p.handCard )

        GameEvent.PlaceHand p ->
            ( AwaitingHandRect entry, Just p.handCard )

        GameEvent.Split _ ->
            ( ExecutingAction entry, Nothing )

        GameEvent.CompleteTurn ->
            ( ExecutingAction entry, Nothing )

        GameEvent.Undo ->
            Debug.todo
                "Animate.startNextAction: Undo reached the queue (collapseUndos should have stripped it)"


{-| Host calls this when its `Browser.Dom.getElement` for the
hand card resolves. We compute the destination from the
pending action's payload + the live board rect, hand it to
`HandDragAnimate.start`, and transition to
`AnimatingHandAction`.

If `boardRect` is missing (replay started before the live
board was ever measured) we can't translate board-frame
locations into viewport coords; in that case we fall back to
applying the event immediately so the queue keeps moving.
-}
handCardRectReceived :
    Int
    -> Browser.Dom.Element
    -> Maybe GA.Rect
    -> ReplayState
    -> ReplayState
handCardRectReceived nowMs element maybeBoardRect rs =
    case rs.phase of
        AwaitingHandRect entry ->
            case handAnimationFor entry (elementTopLeftInViewport element) maybeBoardRect nowMs of
                Just handState ->
                    { rs | phase = AnimatingHandAction handState }

                Nothing ->
                    { rs
                        | gameState = Execute.applyEvent entry.action rs.gameState
                        , phase = InBeat { nextBeatMs = nowMs + beatMs }
                    }

        _ ->
            -- Wrong phase (rect arrived after we transitioned
            -- away — pause-toggled, replay completed, etc.).
            -- Drop the late result.
            rs


{-| Build the hand-animation State for a popped hand action.
Dispatches by variant to compute the floater's destination
in viewport coords, then composes `HandDragAnimate.start`.
Returns Nothing when `boardRect` is missing — the only
reason this can fail by construction.
-}
handAnimationFor : ActionLogEntry -> Point -> Maybe GA.Rect -> Int -> Maybe HandDragAnimate.State
handAnimationFor entry origin maybeBoardRect nowMs =
    case maybeBoardRect of
        Nothing ->
            Nothing

        Just boardRect ->
            case entry.action of
                GameEvent.MergeHand p ->
                    let
                        size =
                            CardStack.size p.target

                        landingLeft =
                            case p.side of
                                BoardActions.Right ->
                                    p.target.loc.left + size * BG.cardPitch

                                BoardActions.Left ->
                                    p.target.loc.left - BG.cardPitch
                    in
                    Just
                        (HandDragAnimate.start
                            { handCard = p.handCard
                            , origin = origin
                            , destination =
                                { x = boardRect.x + landingLeft
                                , y = boardRect.y + p.target.loc.top
                                }
                            , startMs = nowMs
                            , pendingAction = entry.action
                            }
                        )

                GameEvent.PlaceHand p ->
                    Just
                        (HandDragAnimate.start
                            { handCard = p.handCard
                            , origin = origin
                            , destination =
                                { x = boardRect.x + p.loc.left
                                , y = boardRect.y + p.loc.top
                                }
                            , startMs = nowMs
                            , pendingAction = entry.action
                            }
                        )

                _ ->
                    Debug.todo
                        "Animate.handAnimationFor: AwaitingHandRect entry must carry a hand action"


elementTopLeftInViewport : Browser.Dom.Element -> Point
elementTopLeftInViewport element =
    { x = round (element.element.x - element.viewport.x)
    , y = round (element.element.y - element.viewport.y)
    }
