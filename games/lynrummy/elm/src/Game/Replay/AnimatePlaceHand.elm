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

import Game.Card exposing (Card)
import Game.CardStack exposing (BoardLocation)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State
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


prepare : { handCard : Card, loc : BoardLocation } -> Model -> Maybe PrepareResult
prepare payload model =
    Space.handCardSource payload.handCard model
        |> Maybe.map
            (\source ->
                { source = source
                , handCardToMeasure = payload.handCard
                }
            )



-- PHASE 2: FINISH


{-| Build the AnimationInfo once the hand card's DOM rect has
arrived. The floater is a single card; its top-left at landing
IS `payload.loc`. Destination is that loc translated to
viewport via the replay board-rect offset.
-}
finish :
    { handCard : Card, loc : BoardLocation }
    -> Point
    -> Float
    -> DragSource
    -> Model
    -> Maybe Space.AnimationInfo
finish payload origin nowMs source model =
    Space.pointInLiveViewport model
        { left = payload.loc.left, top = payload.loc.top }
        |> Maybe.map
            (\target ->
                { startMs = nowMs
                , path = Space.linearPath origin target nowMs
                , source = source
                , pathFrame = ViewportFrame
                , pendingAction = WA.PlaceHand payload
                }
            )
