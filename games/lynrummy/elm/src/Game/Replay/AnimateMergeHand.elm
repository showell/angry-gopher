module Game.Replay.AnimateMergeHand exposing
    ( PrepareResult
    , finish
    , prepare
    )

{-| Replay animation driver for MergeHand — the async case.
A hand card is dragged onto a stack's wing and absorbed.
Hand-origin drags cross the board widget boundary, so the
path is always synthesized (not captured), and the origin
depends on where the hand card currently sits in the live
viewport. That requires a DOM measurement at replay time.

Two-phase interface:

  - `prepare` — called synchronously when the replay FSM
    is about to handle this action. Returns the
    `handCardToMeasure` (so the caller can fire a
    `Browser.Dom.getElement` Task) plus the source +
    grabOffset that need to live in `AwaitingHandRect`
    until the rect arrives.
  - `finish` — called when the Task resolves. Given the
    measured origin, the stashed context, and the current
    model, builds the final `AnimationInfo` using a linearly-
    synthesized viewport-frame path from origin to the target
    stack's edge.

Extracted 2026-04-22 as part of REFACTOR_ELM_REPLAY B1/Axis Y.
Companion: `Game.Replay.AnimatePlaceHand`. Both hand-origin
modules follow the same two-phase shape.

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
    , grabOffset : Point
    , handCardToMeasure : Card
    }


{-| Decide whether this MergeHand's replay can fire, and if so
return what the FSM needs to stash in `AwaitingHandRect` +
which hand card the DOM task should measure. Returns Nothing
when the hand card isn't present — a contract violation
(wire and model have drifted), but total so the FSM can
recover.
-}
prepare : { handCard : Card, target : CardStack, side : Side } -> Model -> Maybe PrepareResult
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


{-| Build the final AnimationInfo once the DOM rect has
arrived. `origin` is the live viewport center of the hand
card (computed via `Space.elementCenterInViewport`). The
target is the current stack's edge in viewport frame
(subject to the live board-rect offset).

Returns Nothing when the target stack can't be resolved —
the board drifted between prepare and rect-arrival, which
shouldn't happen within one animation frame in practice.
-}
finish :
    { handCard : Card, target : CardStack, side : Side }
    -> Point
    -> Float
    -> DragSource
    -> Point
    -> Model
    -> Maybe Space.AnimationInfo
finish payload origin nowMs source grabOffset model =
    CardStack.findStack payload.target model.board
        |> Maybe.andThen
            (\stack ->
                Space.stackEdgeInLiveViewport model stack payload.side
                    |> Maybe.map
                        (\edge ->
                            { startMs = nowMs
                            , path = Space.linearPath origin edge nowMs
                            , source = source
                            , grabOffset = grabOffset
                            , pathFrame = ViewportFrame
                            , pendingAction = WA.MergeHand payload
                            }
                        )
            )
