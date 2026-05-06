module Game.Replay.AnimateMoveStack exposing (start)

{-| Replay animation for MoveStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
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
            (\source ->
                { startMs = nowMs
                , path = path
                , source = source
                , pathFrame = frame
                , pendingAction = WA.MoveStack payload
                }
            )
