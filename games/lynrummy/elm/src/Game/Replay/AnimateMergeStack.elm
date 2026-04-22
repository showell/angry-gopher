module Game.Replay.AnimateMergeStack exposing (start)

{-| Replay animation for a MergeStack primitive. The human drags
one board stack onto another stack's left or right wing; the
result is a single merged stack. Captured path is always
present (server-enforced), so this is the synchronous case.

Extracted 2026-04-22 as part of REFACTOR_ELM_REPLAY B1/Axis X.

-}

import Game.BoardActions exposing (Side)
import Game.CardStack exposing (CardStack)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State as State exposing (Model, PathFrame)


start :
    { source : CardStack, target : CardStack, side : Side }
    -> List State.GesturePoint
    -> PathFrame
    -> Model
    -> Float
    -> Maybe Space.AnimationInfo
start payload path frame model nowMs =
    Space.boardStackSource payload.source model
        |> Maybe.map
            (\( source, grabOffset ) ->
                { startMs = nowMs
                , path = path
                , source = source
                , grabOffset = grabOffset
                , pathFrame = frame
                , pendingAction = WA.MergeStack payload
                }
            )
