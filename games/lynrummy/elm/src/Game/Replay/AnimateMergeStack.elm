module Game.Replay.AnimateMergeStack exposing (start)

{-| Replay animation for MergeStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
-}

import Game.BoardActions exposing (Side)
import Game.CardStack exposing (CardStack)
import Game.GameEvent as GameEvent
import Game.Replay.Space as Space
import Game.TimeLoc exposing (TimeLoc)


start :
    { source : CardStack, target : CardStack, side : Side, boardPath : List TimeLoc }
    -> List CardStack
    -> Float
    -> Maybe Space.AnimationInfo
start payload board nowMs =
    Space.boardStackSource payload.source board
        |> Maybe.map
            (\source ->
                { startMs = nowMs
                , path = payload.boardPath
                , source = source
                , pendingAction = GameEvent.MergeStack payload
                }
            )
