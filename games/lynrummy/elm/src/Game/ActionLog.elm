module Game.ActionLog exposing
    ( ActionLogBundle
    , ActionLogEntry
    )

import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent)


type alias ActionLogEntry =
    { action : GameEvent }


type alias ActionLogBundle =
    { initialState : GameState
    , actions : List ActionLogEntry
    }
