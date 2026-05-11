module Game.HandDrag exposing
    ( HandOutcome
    , HandleMouseUpInput
    , handleMouseUp
    )

import Game.ActionLog exposing (ActionLogEntry)
import Game.CardStack exposing (CardStack)
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent
import Game.Hand as Hand exposing (Hand)
import Game.HandDragTypes exposing (HandCardDragInfo)
import Game.HandGesture as HandGesture
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.Status as Status exposing (StatusMessage)


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
    , hands : List Hand
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
                next =
                    Execute.mergeHand p.handCard p.target p.side input.gameState.board (Hand.activeHand input.gameState)

                gsWithHand =
                    Hand.setActiveHand next.hand input.gameState
            in
            { board = next.board
            , hands = gsWithHand.hands
            , cardsPlayedThisTurn = input.gameState.cardsPlayedThisTurn + 1
            , status = Status.geometryFeedback input.gameState.board next.board |> Maybe.withDefault (Status.mergeStatus next.board)
            , actionLog =
                input.actionLog
                    ++ [ { action = GameEvent.MergeHand p } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload = Just (GameEvent.mergeHandDsl input.nextSeq p.handCard p.target p.side)
            }

        HandGesture.PlaceHand p ->
            let
                next =
                    Execute.placeHand p.handCard p.loc input.gameState.board (Hand.activeHand input.gameState)

                gsWithHand =
                    Hand.setActiveHand next.hand input.gameState

                placeHandStatus =
                    { text = "On the board!", kind = Status.Inform }
            in
            { board = next.board
            , hands = gsWithHand.hands
            , cardsPlayedThisTurn = input.gameState.cardsPlayedThisTurn + 1
            , status = Status.geometryFeedback input.gameState.board next.board |> Maybe.withDefault placeHandStatus
            , actionLog =
                input.actionLog
                    ++ [ { action = GameEvent.PlaceHand p } ]
            , nextSeq = input.nextSeq + 1
            , outboundPayload = Just (GameEvent.placeHandDsl input.nextSeq p.handCard p.loc)
            }

        HandGesture.HandCardOffBoard ->
            { board = input.gameState.board
            , hands = input.gameState.hands
            , cardsPlayedThisTurn = input.gameState.cardsPlayedThisTurn
            , status = Status.offBoardScold
            , actionLog = input.actionLog
            , nextSeq = input.nextSeq
            , outboundPayload = Nothing
            }

        HandGesture.HandNothing ->
            { board = input.gameState.board
            , hands = input.gameState.hands
            , cardsPlayedThisTurn = input.gameState.cardsPlayedThisTurn
            , status = Status.handNothingStatus
            , actionLog = input.actionLog
            , nextSeq = input.nextSeq
            , outboundPayload = Nothing
            }
