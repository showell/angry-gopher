module Lib.TurnControl exposing
    ( CompleteTurnAttempt(..)
    , UndoAttempt(..)
    , attemptCompleteTurn
    , attemptUndo
    )

{-| The two turn-boundary actions: "Complete turn" and "Undo."
Each returns a typed variant the caller dispatches on. DSL
wire lines are returned as `outboundPayload : String` — the
host wraps them in `Wire.sendAction` at the call site.
-}

import Lib.ActionLog exposing (ActionLogEntry)
import Lib.Execute as Execute
import Lib.Game as Game exposing (GameState)
import Lib.GameEvent as GameEvent exposing (GameEvent)
import Lib.Physics.BoardGeometry exposing (refereeBounds)
import Lib.PlayerTurn exposing (CompleteTurnResult(..))
import Lib.Popup as Popup exposing (PopupContent)
import Lib.Status as Status exposing (StatusMessage)


type CompleteTurnAttempt
    = TurnRejected
        { status : StatusMessage
        , popup : PopupContent
        }
    | TurnCompleted
        { newGameState : GameState
        , appendedEntry : ActionLogEntry
        , status : StatusMessage
        , popup : PopupContent
        , outboundPayload : String
        }


type UndoAttempt
    = NothingToUndo
    | DidUndo
        { newGameState : GameState
        , appendedEntry : ActionLogEntry
        , outboundPayload : String
        }



-- COMPLETE TURN


attemptCompleteTurn :
    { gameState : GameState, nextSeq : Int }
    -> CompleteTurnAttempt
attemptCompleteTurn { gameState, nextSeq } =
    let
        ( afterTurn, turnOutcome ) =
            Game.applyCompleteTurn refereeBounds gameState

        status =
            Status.statusForCompleteTurn (Ok turnOutcome)

        popup =
            Popup.popupForCompleteTurn (Ok turnOutcome)
    in
    case turnOutcome.result of
        Failure ->
            TurnRejected { status = status, popup = popup }

        _ ->
            TurnCompleted
                { newGameState = afterTurn
                , appendedEntry = { action = GameEvent.CompleteTurn }
                , status = status
                , popup = popup
                , outboundPayload = GameEvent.completeTurnDsl nextSeq
                }



-- UNDO


attemptUndo :
    { gameState : GameState
    , lastUndoableAction : Maybe GameEvent
    , nextSeq : Int
    }
    -> UndoAttempt
attemptUndo { gameState, lastUndoableAction, nextSeq } =
    case lastUndoableAction of
        Nothing ->
            NothingToUndo

        Just lastAction ->
            DidUndo
                { newGameState = undoEvent lastAction gameState
                , appendedEntry = { action = GameEvent.Undo }
                , outboundPayload = GameEvent.undoDsl nextSeq
                }


{-| Re-export under a local name to avoid an extra import in
the caller. (Lib.Execute.undoEvent is the canonical apply.)
-}
undoEvent : GameEvent -> GameState -> GameState
undoEvent =
    Execute.undoEvent
