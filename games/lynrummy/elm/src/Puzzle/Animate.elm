module Puzzle.Animate exposing
    ( AnimationState
    , Phase(..)
    , TickResult(..)
    , start
    , tick
    , togglePause
    )

{-| Sibling of `Game.Animation.Animate`. Simpler: replays
operate on a board (`List CardStack`) directly — puzzles
have no hand, no turn cycle, no DOM measurement. Only
`MergeStack`, `MoveStack`, and `Split` are expected in the
queue; anything else is a contract violation.

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.CardStack exposing (CardStack)
import Game.Execute as Execute
import Game.GameEvent as GameEvent
import Game.Animation.BoardDragAnimate as BoardDragAnimate


type Phase
    = Starting
    | InBeat { nextBeatMs : Int }
    | ActionCompleted
    | AnimatingBoardAction BoardDragAnimate.State


type alias AnimationState =
    { queue : List ActionLogEntry
    , board : List CardStack
    , paused : Bool
    , phase : Phase
    }


type TickResult
    = StillAnimating AnimationState
    | Completed


beatMs : Int
beatMs =
    700


start : List ActionLogEntry -> List CardStack -> AnimationState
start queue board =
    { queue = queue
    , board = board
    , paused = False
    , phase = Starting
    }


togglePause : AnimationState -> AnimationState
togglePause rs =
    let
        nextPhase =
            case rs.phase of
                InBeat _ ->
                    Starting

                _ ->
                    rs.phase
    in
    { rs | paused = not rs.paused, phase = nextPhase }


tick : Int -> AnimationState -> TickResult
tick nowMs rs =
    case rs.phase of
        Starting ->
            StillAnimating { rs | phase = InBeat { nextBeatMs = nowMs + beatMs } }

        InBeat { nextBeatMs } ->
            if nowMs < nextBeatMs then
                StillAnimating rs

            else
                case rs.queue of
                    [] ->
                        Completed

                    entry :: rest ->
                        let
                            dispatched =
                                startNextAction nowMs entry rs.board
                        in
                        StillAnimating
                            { rs
                                | queue = rest
                                , board = dispatched.board
                                , phase = dispatched.phase
                            }

        ActionCompleted ->
            StillAnimating { rs | phase = InBeat { nextBeatMs = nowMs + beatMs } }

        AnimatingBoardAction dragState ->
            case BoardDragAnimate.step nowMs rs.board dragState of
                BoardDragAnimate.InProgress nextDragState ->
                    StillAnimating { rs | phase = AnimatingBoardAction nextDragState }

                BoardDragAnimate.Done { newBoard } ->
                    StillAnimating { rs | board = newBoard, phase = ActionCompleted }


startNextAction :
    Int
    -> ActionLogEntry
    -> List CardStack
    ->
        { board : List CardStack
        , phase : Phase
        }
startNextAction nowMs entry board =
    case entry.action of
        GameEvent.MergeStack p ->
            { board = board
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
            { board = board
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

        GameEvent.Split p ->
            { board = Execute.split p.stack p.cardIndex board
            , phase = ActionCompleted
            }

        _ ->
            Debug.todo
                "Puzzle.Animate: unexpected event variant — puzzles only emit Split / MergeStack / MoveStack"
