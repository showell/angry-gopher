module Lib.Undo exposing
    ( UndoAttempt(..)
    , attemptUndo
    , canUndoThisTurn
    )

{-| Host-facing undo wrapper + the action-log predicates that
decide whether undo is currently available.

The per-event reverser (`undoEvent`) lives in `Lib.Execute`
(intrinsically tied to forward execution) and the log-walking
collapse algorithm (`collapseUndos`) lives in `Lib.ActionLog`
(intrinsically tied to the action log). This module just
composes them into the wrapper + predicates the host UI uses.

-}

import Lib.ActionLog as ActionLog exposing (ActionLogEntry)
import Lib.Execute as Execute
import Lib.GameEvent as GameEvent exposing (GameEvent(..))
import Lib.GameState exposing (GameState)


type UndoAttempt
    = NothingToUndo
    | DidUndo
        { newGameState : GameState
        , appendedEntry : ActionLogEntry
        , outboundPayload : String
        }


attemptUndo :
    { gameState : GameState
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }
    -> UndoAttempt
attemptUndo { gameState, actionLog, nextSeq } =
    case lastUndoableAction actionLog of
        Nothing ->
            NothingToUndo

        Just lastAction ->
            DidUndo
                { newGameState = Execute.undoEvent lastAction gameState
                , appendedEntry = { action = GameEvent.Undo }
                , outboundPayload = GameEvent.undoDsl nextSeq
                }


{-| True when clicking Undo would do something — the effective
action list has at least one non-CompleteTurn entry in the
current turn.
-}
canUndoThisTurn : List ActionLogEntry -> Bool
canUndoThisTurn log =
    lastUndoableAction log /= Nothing


{-| The most recent action eligible for undo, or Nothing.
"Eligible" = top of `collapseUndos`'s effective list AND not a
CompleteTurn (turn flips can't be undone).
-}
lastUndoableAction : List ActionLogEntry -> Maybe GameEvent
lastUndoableAction log =
    case List.reverse (ActionLog.collapseUndos log) of
        [] ->
            Nothing

        last :: _ ->
            case last.action of
                CompleteTurn ->
                    Nothing

                _ ->
                    Just last.action
