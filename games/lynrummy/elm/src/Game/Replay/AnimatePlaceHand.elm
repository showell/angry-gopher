module Game.Replay.AnimatePlaceHand exposing
    ( PrepareResult
    , finish
    , prepare
    )

{-| Replay animation driver for PlaceHand — the async case.
A hand card is dragged to an empty spot on the board,
becoming a new single-card stack at that location. Same
two-phase shape as `Game.Replay.AnimateMergeHand`; the only
per-primitive difference is how the target endpoint is
computed (PlaceHand uses the explicit `loc` payload field,
translated through the live board-rect offset).

Extracted 2026-04-22 as part of REFACTOR_ELM_REPLAY B1/Axis Y.

-}

import Game.BoardGeometry as BG
import Game.Card exposing (Card)
import Game.CardStack exposing (BoardLocation)
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
    , grabOffset : Point
    , handCardToMeasure : Card
    }


prepare : { handCard : Card, loc : BoardLocation } -> Model -> Maybe PrepareResult
prepare payload model =
    Space.handCardSource payload.handCard model
        |> Maybe.map
            (\( source, grabOffset ) ->
                { source = source
                , grabOffset = grabOffset
                , handCardToMeasure = payload.handCard
                }
            )



-- PHASE 2: FINISH


{-| Build the AnimationInfo for a PlaceHand once the DOM rect
has arrived. The target is the payload's `loc` translated from
board frame into live viewport frame via the replay board-rect
offset, with `cardHeight / 2` added to y so the drag lands on
the card's vertical center.
-}
finish :
    { handCard : Card, loc : BoardLocation }
    -> Point
    -> Float
    -> DragSource
    -> Point
    -> Model
    -> Maybe Space.AnimationInfo
finish payload origin nowMs source grabOffset model =
    Space.pointInLiveViewport model
        { left = payload.loc.left, top = payload.loc.top }
        |> Maybe.map
            (\viewportLoc ->
                { startMs = nowMs
                , path =
                    Space.linearPath origin
                        { x = viewportLoc.x
                        , y = viewportLoc.y + BG.cardHeight // 2
                        }
                        nowMs
                , source = source
                , grabOffset = grabOffset
                , pathFrame = ViewportFrame
                , pendingAction = WA.PlaceHand payload
                }
            )
