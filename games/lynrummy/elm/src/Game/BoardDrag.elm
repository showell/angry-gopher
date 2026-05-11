module Game.BoardDrag exposing
    ( BoardOutcome
    , HandleMouseUpInput
    , handleMouseUp
    )

import Game.ActionLog exposing (ActionLogEntry)
import Game.BoardDragTypes exposing (BoardCardDragInfo)
import Game.BoardGesture as BoardGesture
import Game.CardStack exposing (CardStack)
import Game.Execute as Execute
import Game.GameEvent as GameEvent
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.Status as Status exposing (StatusMessage)


{-| Inputs `handleMouseUp` reads from the host model. Caller
patches the resulting `BoardOutcome` back onto its own state.
-}
type alias HandleMouseUpInput =
    { board : List CardStack
    , boardRect : Maybe GA.Rect
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }


{-| Result of resolving a board-card mouseup. The caller patches
`board / status / actionLog / nextSeq` onto its model and (if
present) ships `outboundPayload` over the wire — this module
doesn't know about Cmd or session ids, keeping it host-
agnostic so Puzzles can call it without a wire.
-}
type alias BoardOutcome =
    { board : List CardStack
    , status : StatusMessage
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    , outboundPayload : Maybe String
    }


{-| Resolve a board-card mouseup. Each action variant produces
the new board state, an action-log append, and (for accepted
actions) the DSL line the host should ship to the agent. Each
case constructs the DSL line directly via the matching
`GameEvent.*Dsl` helper — no GameEvent value built just to
re-dispatch on it.
-}
handleMouseUp : Point -> Int -> BoardCardDragInfo -> HandleMouseUpInput -> BoardOutcome
handleMouseUp releasePoint tMs d input =
    case BoardGesture.handleMouseUp releasePoint tMs d input.boardRect of
        BoardGesture.Split p ->
            let
                newBoard =
                    Execute.split p.stack p.cardIndex input.board

                splitStatus =
                    { text = "Be careful with splitting! Splits only pay off when you get more cards on the board or make prettier piles."
                    , kind = Status.Scold
                    }
            in
            { board = newBoard
            , status = Status.geometryFeedback input.board newBoard |> Maybe.withDefault splitStatus
            , actionLog = input.actionLog ++ [ { action = GameEvent.Split p } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload = Just (GameEvent.splitDsl input.nextSeq p.stack p.cardIndex)
            }

        BoardGesture.MergeStack p ->
            let
                newBoard =
                    Execute.mergeStack p.source p.target p.side input.board

                event =
                    GameEvent.MergeStack
                        { source = p.source
                        , target = p.target
                        , side = p.side
                        , boardPath = p.boardPath
                        }
            in
            { board = newBoard
            , status = Status.geometryFeedback input.board newBoard |> Maybe.withDefault (Status.mergeStatus newBoard)
            , actionLog = input.actionLog ++ [ { action = event } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload =
                Just (GameEvent.mergeStackDsl input.nextSeq p.source p.target p.side p.boardPath)
            }

        BoardGesture.MoveStack p ->
            let
                newBoard =
                    Execute.moveStack p.stack p.newLoc input.board

                moveStackStatus =
                    { text = "Moved!", kind = Status.Inform }

                event =
                    GameEvent.MoveStack
                        { stack = p.stack
                        , newLoc = p.newLoc
                        , boardPath = p.boardPath
                        }
            in
            { board = newBoard
            , status = Status.geometryFeedback input.board newBoard |> Maybe.withDefault moveStackStatus
            , actionLog = input.actionLog ++ [ { action = event } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload =
                Just (GameEvent.moveStackDsl input.nextSeq p.stack p.newLoc p.boardPath)
            }

        BoardGesture.BoardCardOffBoard ->
            { board = input.board
            , status = Status.offBoardScold
            , actionLog = input.actionLog
            , nextSeq = input.nextSeq
            , outboundPayload = Nothing
            }
