module Game.Replay.AnimateMoveStack exposing (start)

{-| Replay animation for MoveStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
-}

import Game.CardStack exposing (CardStack, BoardLocation)
import Game.Replay.Space as Space
import Game.GameEvent as GameEvent
import Main.State exposing (Model)
import Main.Types exposing (GesturePoint)


start :
    { stack : CardStack, newLoc : BoardLocation }
    -> List GesturePoint
    -> Model
    -> Float
    -> Maybe Space.AnimationInfo
start payload path model nowMs =
    Space.boardStackSource payload.stack model
        |> Maybe.map
            (\source ->
                { startMs = nowMs
                , path = path
                , source = source
                , pendingAction = GameEvent.MoveStack payload
                }
            )
