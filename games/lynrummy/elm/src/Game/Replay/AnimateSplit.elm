module Game.Replay.AnimateSplit exposing (start)

{-| Replay animation for a Split primitive. The human (or agent)
drags a card at `cardIndex` away from its stack; the stack
cleaves into two halves at that point. Captured path is
always present (server enforces `requiresGestureMetadata` for
intra-board actions), so this is the synchronous case — no
DOM measurement needed.

Extracted 2026-04-22 as part of REFACTOR_ELM_REPLAY B1/Axis X.
One module per wire-action primitive so each animation's
shape is findable by name and can diverge independently if
a primitive ever earns its own replay style.

-}

import Game.CardStack exposing (CardStack)
import Game.Replay.Space as Space
import Game.WireAction as WA
import Main.State as State exposing (Model, PathFrame)


start :
    { stack : CardStack, cardIndex : Int }
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
                , pendingAction = WA.Split payload
                }
            )
