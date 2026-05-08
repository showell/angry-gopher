module Game.Replay.AnimateMoveStack exposing (start)

{-| Replay animation for MoveStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
-}

import Game.CardStack exposing (CardStack, BoardLocation)
import Game.GameEvent as GameEvent
import Game.Replay.Space as Space
import Game.TimeLoc exposing (TimeLoc)


start :
    { stack : CardStack, newLoc : BoardLocation, boardPath : List TimeLoc }
    -> List CardStack
    -> Float
    -> Maybe Space.AnimationInfo
start payload board nowMs =
    Space.boardStackSource payload.stack board
        |> Maybe.map
            (\source ->
                { startMs = nowMs
                , path = payload.boardPath
                , source = source
                , pendingAction = GameEvent.MoveStack payload
                }
            )
