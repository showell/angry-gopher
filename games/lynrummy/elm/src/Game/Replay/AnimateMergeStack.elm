module Game.Replay.AnimateMergeStack exposing (start)

{-| Replay animation for MergeStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
-}

import Game.BoardActions exposing (Side)
import Game.CardStack exposing (CardStack)
import Game.Replay.Space as Space
import Game.GameEvent as GameEvent
import Main.Types exposing (GesturePoint)


start :
    { source : CardStack, target : CardStack, side : Side }
    -> List GesturePoint
    -> List CardStack
    -> Float
    -> Maybe Space.AnimationInfo
start payload path board nowMs =
    Space.boardStackSource payload.source board
        |> Maybe.map
            (\source ->
                { startMs = nowMs
                , path = path
                , source = source
                , pendingAction = GameEvent.MergeStack payload
                }
            )
