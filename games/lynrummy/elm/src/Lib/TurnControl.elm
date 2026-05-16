module Lib.TurnControl exposing
    ( CompleteTurnAttempt(..)
    , attemptCompleteTurn
    )

{-| Host-facing wrapper around `Lib.CompleteTurn.applyCompleteTurn`:
bundles the transition with the status / popup / wire payload
the UI needs. Kept separate from `Lib.CompleteTurn` because the
wrapper imports `Lib.Popup` and `Lib.Status`, both of which
depend on `Lib.CompleteTurn` for the outcome type — merging
would form a cycle. The companion undo wrapper lives in
`Lib.Undo`.
-}

import Lib.ActionLog exposing (ActionLogEntry)
import Lib.CompleteTurn as CompleteTurn
import Lib.GameEvent as GameEvent
import Lib.GameState exposing (GameState)
import Lib.Physics.BoardGeometry exposing (refereeBounds)
import Lib.PlayerTurn exposing (CompleteTurnResult(..))
import Lib.Popup exposing (PopupContent)
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


attemptCompleteTurn :
    { gameState : GameState, nextSeq : Int }
    -> CompleteTurnAttempt
attemptCompleteTurn { gameState, nextSeq } =
    let
        ( afterTurn, turnOutcome ) =
            CompleteTurn.applyCompleteTurn refereeBounds gameState

        status =
            Status.statusForCompleteTurn (Ok turnOutcome)

        popup =
            CompleteTurn.popupForCompleteTurn (Ok turnOutcome)
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
