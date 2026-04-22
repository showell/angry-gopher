module Game.Replay.AnimateMoveStack exposing (start)

{-| Replay animation for a MoveStack primitive. The human drags
one board stack to an open location on the board — no merge,
just a position change. Captured path is always present
(server-enforced), so this is the synchronous case.

Extracted 2026-04-22 as part of REFACTOR_ELM_REPLAY B1/Axis X.

-}

import Game.CardStack exposing (CardStack, BoardLocation)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State as State exposing (Model, PathFrame)


start :
    { stack : CardStack, newLoc : BoardLocation }
    -> List State.GesturePoint
    -> PathFrame
    -> Model
    -> Float
    -> Maybe Space.AnimationInfo
start payload path frame model nowMs =
    Space.boardStackSource payload.stack model
        |> Maybe.map
            (\( source, grabOffset ) ->
                { startMs = nowMs
                , path = path
                , source = source
                , grabOffset = grabOffset
                , pathFrame = frame
                , pendingAction = WA.MoveStack payload
                }
            )
