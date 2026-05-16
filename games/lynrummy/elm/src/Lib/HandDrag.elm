module Lib.HandDrag exposing
    ( HandOutcome
    , HandleMouseUpInput
    , handleMouseUp
    )

import Lib.ActionLog exposing (ActionLogEntry)
import Lib.CardStack exposing (CardStack)
import Lib.Execute as Execute
import Lib.GameState exposing (GameState)
import Lib.GameEvent as GameEvent
import Lib.Hand exposing (Hand)
import Lib.HandDragTypes exposing (HandCardDragInfo)
import Lib.HandGesture as HandGesture
import Lib.Physics.GestureArbitration as GA
import Lib.Point exposing (Point)
import Lib.Status as Status exposing (StatusMessage)


{-| Inputs `handleMouseUp` reads. The hand variant needs the
whole `gameState` because it touches `board`, `hands`, and
`cardsPlayedThisTurn`.
-}
type alias HandleMouseUpInput =
    { gameState : GameState
    , boardRect : Maybe GA.Rect
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }


{-| Result of resolving a hand-card mouseup. Mirrors
`BoardOutcome` but with the additional fields a hand action
mutates (`hands` write-back, `cardsPlayedThisTurn` bump).
`outboundPayload` is `Nothing` for the no-op variants.
-}
type alias HandOutcome =
    { board : List CardStack
    , humanHand : Hand
    , agentHand : Hand
    , cardsPlayedThisTurn : Int
    , status : StatusMessage
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    , outboundPayload : Maybe String
    }


{-| Resolve a hand-card mouseup. Hand actions ship pathless
(no `gesture_metadata`); replay re-synthesizes via DOM
measurement on the resume path.
-}
handleMouseUp : Point -> HandCardDragInfo -> HandleMouseUpInput -> HandOutcome
handleMouseUp releasePoint d input =
    case HandGesture.handleMouseUp releasePoint d input.boardRect of
        HandGesture.MergeHand p ->
            let
                nextState =
                    Execute.mergeHand p.handCard p.target p.side input.gameState
            in
            { board = nextState.board
            , humanHand = nextState.humanHand
            , agentHand = nextState.agentHand
            , cardsPlayedThisTurn = nextState.cardsPlayedThisTurn
            , status = Status.geometryFeedback input.gameState.board nextState.board |> Maybe.withDefault (Status.mergeStatus nextState.board)
            , actionLog =
                input.actionLog
                    ++ [ { action = GameEvent.MergeHand p } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload = Just (GameEvent.mergeHandDsl input.nextSeq p.handCard p.target p.side)
            }

        HandGesture.PlaceHand p ->
            let
                nextState =
                    Execute.placeHand p.handCard p.loc input.gameState

                placeHandStatus =
                    { text = "On the board!", kind = Status.Inform }
            in
            { board = nextState.board
            , humanHand = nextState.humanHand
            , agentHand = nextState.agentHand
            , cardsPlayedThisTurn = nextState.cardsPlayedThisTurn
            , status = Status.geometryFeedback input.gameState.board nextState.board |> Maybe.withDefault placeHandStatus
            , actionLog =
                input.actionLog
                    ++ [ { action = GameEvent.PlaceHand p } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload = Just (GameEvent.placeHandDsl input.nextSeq p.handCard p.loc)
            }

        HandGesture.HandCardOffBoard ->
            { board = input.gameState.board
            , humanHand = input.gameState.humanHand
            , agentHand = input.gameState.agentHand
            , cardsPlayedThisTurn = input.gameState.cardsPlayedThisTurn
            , status = Status.offBoardScold
            , actionLog = input.actionLog
            , nextSeq = input.nextSeq
            , outboundPayload = Nothing
            }

        HandGesture.HandNothing ->
            { board = input.gameState.board
            , humanHand = input.gameState.humanHand
            , agentHand = input.gameState.agentHand
            , cardsPlayedThisTurn = input.gameState.cardsPlayedThisTurn
            , status = Status.handNothingStatus
            , actionLog = input.actionLog
            , nextSeq = input.nextSeq
            , outboundPayload = Nothing
            }
