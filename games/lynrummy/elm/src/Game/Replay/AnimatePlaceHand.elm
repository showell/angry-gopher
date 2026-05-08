module Game.Replay.AnimatePlaceHand exposing
    ( PrepareResult
    , finish
    , prepare
    )

{-| Replay animation driver for PlaceHand. Two-phase:
`prepare` synchronously resolves the source hand card;
`finish` synthesizes the drag path once the DOM rect arrives.
Companion to `AnimateMergeHand` — same shape, different
target endpoint (PlaceHand uses the payload's explicit `loc`).
-}

import Game.Game exposing (GameState)
import Game.Physics.GestureArbitration as GA
import Game.Rules.Card exposing (Card)
import Game.CardStack exposing (BoardLocation)
import Game.Replay.Space as Space
import Game.GameEvent as GameEvent
import Main.Types exposing (Point)



-- PHASE 1: PREPARE


type alias PrepareResult =
    { handCardToMeasure : Card
    }


prepare : { handCard : Card, loc : BoardLocation } -> GameState -> Maybe PrepareResult
prepare payload gameState =
    Space.handCardSource payload.handCard gameState
        |> Maybe.map (\_ -> { handCardToMeasure = payload.handCard })



-- PHASE 2: FINISH


{-| Build the AnimationInfo once the hand card's DOM rect has
arrived. The floater is a single card; its top-left at landing
IS `payload.loc`. Destination is that loc translated to
viewport via the live board-rect offset.
-}
finish :
    { handCard : Card, loc : BoardLocation }
    -> Point
    -> Float
    -> GameState
    -> Maybe GA.Rect
    -> Maybe Space.AnimationInfo
finish payload origin nowMs gameState maybeBoardRect =
    case Space.handCardSource payload.handCard gameState of
        Nothing ->
            Nothing

        Just source ->
            Space.pointInLiveViewport maybeBoardRect
                { left = payload.loc.left, top = payload.loc.top }
                |> Maybe.map
                    (\target ->
                        { startMs = nowMs
                        , path = Space.linearPath origin target nowMs
                        , source = source
                        , pendingAction = GameEvent.PlaceHand payload
                        }
                    )
