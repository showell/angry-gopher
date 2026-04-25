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
    measurement and returns the source identity to stash in
    `AwaitingHandRect`.
  - `finish` — called when the DOM task resolves; synthesizes
    a linear viewport-frame path from origin to landing.

Companion: `Game.Replay.AnimatePlaceHand`.
-}

import Game.BoardActions exposing (Side)
import Game.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State as State
    exposing
        ( DragSource
        , Model
        , PathFrame(..)
        , Point
        )



-- PHASE 1: PREPARE


type alias PrepareResult =
    { source : DragSource
    , handCardToMeasure : Card
    }


{-| Resolve the source hand card and name it for DOM
measurement. Returns Nothing if the card isn't in the current
hand — treated as a wire/model drift rather than a crash.
-}
prepare : { handCard : Card, target : CardStack, side : Side } -> Model -> Maybe PrepareResult
prepare payload model =
    Space.handCardSource payload.handCard model
        |> Maybe.map
            (\source ->
                { source = source
                , handCardToMeasure = payload.handCard
                }
            )



-- PHASE 2: FINISH


{-| Build the AnimationInfo once the DOM rect has arrived.
`origin` is the hand card's viewport top-left; target is the
floater's landing top-left in viewport (from
`Space.stackLandingInLiveViewport`). Returns Nothing if the
target stack drifted between prepare and rect-arrival.
-}
finish :
    { handCard : Card, target : CardStack, side : Side }
    -> Point
    -> Float
    -> DragSource
    -> Model
    -> Maybe Space.AnimationInfo
finish payload origin nowMs source model =
    CardStack.findStack payload.target model.board
        |> Maybe.andThen
            (\stack ->
                Space.stackLandingInLiveViewport model stack payload.side
                    |> Maybe.map
                        (\landing ->
                            { startMs = nowMs
                            , path = Space.linearPath origin landing nowMs
                            , source = source
                            , pathFrame = ViewportFrame
                            , pendingAction = WA.MergeHand payload
                            }
                        )
            )
