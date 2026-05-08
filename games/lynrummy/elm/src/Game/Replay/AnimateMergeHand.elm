module Game.Replay.AnimateMergeHand exposing
    ( PrepareResult
    , finish
    , prepare
    )

{-| Replay animation driver for MergeHand. Hand-origin drags
cross the board widget boundary, so the path is always
synthesized (not captured) and the origin depends on the hand
card's current live viewport position — which requires a
DOM measurement at replay time.

Two phases:

  - `prepare` — synchronous; names which hand card needs DOM
    measurement.
  - `finish` — called when the DOM task resolves; synthesizes
    a linear viewport-frame path from origin to landing.

Companion: `Game.Replay.AnimatePlaceHand`.

-}

import Game.BoardActions exposing (Side)
import Game.Game exposing (GameState)
import Game.Physics.GestureArbitration as GA
import Game.Rules.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack)
import Game.Replay.Space as Space
import Game.GameEvent as GameEvent
import Main.Types exposing (Point)



-- PHASE 1: PREPARE


type alias PrepareResult =
    { handCardToMeasure : Card
    }


{-| Resolve the source hand card and name it for DOM
measurement. Returns Nothing if the card isn't in the current
hand — treated as a wire/model drift rather than a crash.
-}
prepare : { handCard : Card, target : CardStack, side : Side } -> GameState -> Maybe PrepareResult
prepare payload gameState =
    Space.handCardSource payload.handCard gameState
        |> Maybe.map (\_ -> { handCardToMeasure = payload.handCard })



-- PHASE 2: FINISH


{-| Build the AnimationInfo once the DOM rect has arrived.
`origin` is the hand card's viewport top-left; target is the
floater's landing top-left in viewport (from
`Space.stackLandingInLiveViewport`). Returns Nothing if the
target stack drifted between prepare and rect-arrival OR if
the hand card is no longer in the active hand.
-}
finish :
    { handCard : Card, target : CardStack, side : Side }
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
            CardStack.findStack payload.target gameState.board
                |> Maybe.andThen
                    (\stack ->
                        Space.stackLandingInLiveViewport maybeBoardRect stack payload.side
                            |> Maybe.map
                                (\landing ->
                                    let
                                        viewportPath =
                                            Space.linearPath origin landing nowMs
                                    in
                                    { startMs = nowMs
                                    , path = viewportPath
                                    , source = source
                                    , pendingAction = GameEvent.MergeHand payload
                                    }
                                )
                    )
