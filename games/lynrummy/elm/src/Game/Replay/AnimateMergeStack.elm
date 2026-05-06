module Game.Replay.AnimateMergeStack exposing (start)

{-| Replay animation for MergeStack. Captured path is always
present (server-enforced), so synchronous — no DOM measure.
-}

import Game.BoardActions exposing (Side)
import Game.CardStack exposing (CardStack)
import Game.Replay.Snapshot exposing (Snapshot)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State as State exposing (PathFrame)


start :
    { source : CardStack, target : CardStack, side : Side }
    -> List State.GesturePoint
    -> PathFrame
    -> Snapshot
    -> Float
    -> Maybe Space.AnimationInfo
start payload path frame snapshot nowMs =
    Space.boardStackSource payload.source snapshot
        |> Maybe.map
            (\source ->
                { startMs = nowMs
                , path = path
                , source = source
                , pathFrame = frame
                , pendingAction = WA.MergeStack payload
                }
            )
