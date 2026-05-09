module Game.TurnControl exposing
    ( CompleteTurnAttempt(..)
    , UndoAttempt(..)
    , attemptCompleteTurn
    , attemptUndo
    )

{-| Pure logic for the two turn-boundary actions: "Complete
turn" and "Undo." Each returns a typed variant the caller
(Main.Play) dispatches on to patch Model + fire the wire
Cmd.

This module is Cmd-free and Msg-free — the Encode.Value
payloads are returned as data; the host wraps them in
`Wire.sendAction` at the call site.

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.Execute as Execute
import Game.Game as Game exposing (GameState)
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.Physics.BoardGeometry exposing (refereeBounds)
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.Popup as Popup exposing (PopupContent)
import Game.Status as Status exposing (StatusMessage)
import Json.Encode as Encode exposing (Value)



-- COMPLETE TURN


type CompleteTurnAttempt
    = TurnRejected
        { status : StatusMessage
        , popup : Maybe PopupContent
        }
    | TurnCompleted
        { newGameState : GameState
        , appendedEntry : ActionLogEntry
        , status : StatusMessage
        , popup : Maybe PopupContent
        , outboundPayload : Value
        }


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
                , outboundPayload =
                    Encode.object
                        [ ( "seq", Encode.int nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "complete_turn" ) ]
                          )
                        ]
                }



-- UNDO


type UndoAttempt
    = NothingToUndo
    | DidUndo
        { newGameState : GameState
        , appendedEntry : ActionLogEntry
        , outboundPayload : Value
        }


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
                , outboundPayload =
                    Encode.object
                        [ ( "seq", Encode.int nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "undo" ) ]
                          )
                        ]
                }


{-| Re-export under a local name to avoid an extra import in
the caller. (Game.Execute.undoEvent is the canonical apply.)
-}
undoEvent : GameEvent -> GameState -> GameState
undoEvent =
    Execute.undoEvent
