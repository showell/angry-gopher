module Game.ActionLog exposing
    ( ActionLogBundle
    , ActionLogEntry
    , EnvelopeForGesture
    )

{-| The action-log shape — leaf module so types can be shared
between Main.State (which holds the live log on Model) and
Game.* drag handlers (which produce log entries).

Extracted 2026-05-08 to break a Main.State ↔ Game.Drag ↔
Game.BoardDrag cycle. The drag modules need `ActionLogEntry`;
they shouldn't have to round-trip through Main.State to get
it.

-}

import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent)
import Main.Types exposing (GesturePoint, PathFrame)


type alias ActionLogEntry =
    { action : GameEvent
    , gesturePath : Maybe (List GesturePoint)
    , pathFrame : PathFrame
    }


type alias ActionLogBundle =
    { initialState : GameState
    , actions : List ActionLogEntry
    }


{-| Captured drag telemetry attached to a wire-bound action: a
sequence of timestamped points plus the coordinate frame those
points live in.
-}
type alias EnvelopeForGesture =
    { path : List GesturePoint, frame : PathFrame }
