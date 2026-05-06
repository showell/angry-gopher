module Game.Replay.AnimateMoveStack exposing (start)

{-| Replay animation for MoveStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
-}

import Game.CardStack exposing (CardStack, BoardLocation)
import Game.Replay.Snapshot exposing (Snapshot)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State as State exposing (PathFrame)


start :
    { stack : CardStack, newLoc : BoardLocation }
    -> List State.GesturePoint
    -> PathFrame
    -> Snapshot
    -> Float
    -> Maybe Space.AnimationInfo
start payload path frame snapshot nowMs =
    Space.boardStackSource payload.stack snapshot
        |> Maybe.map
            (\source ->
                { startMs = nowMs
                , path = path
                , source = source
                , pathFrame = frame
                , pendingAction = WA.MoveStack payload
                }
            )
