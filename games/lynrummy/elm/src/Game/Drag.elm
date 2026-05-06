module Game.Drag exposing (BoardCardDragStartInfo)

{-| Drag-related data shapes shared across surfaces.

Today this module hosts one type: the data produced when a
board-card drag starts. It's lifted out of the game-specific
`Main.State` module so any surface (puzzle, the eventual
real-time-agent visualizer, future what-if tooling) can
construct one without reaching into the game's private
state types.

-}

import Game.Physics.GestureArbitration as GA
import Game.Physics.WingOracle exposing (WingId)
import Main.State exposing (GesturePoint, PathFrame, Point)


{-| The data shape produced when a board-card drag starts —
the union of `DragInfo`, `DragContext`, and `ClickArbiter`
fields modulo `source` (which is implicit at this layer:
this type is for board-card drags, so source is always
`FromBoardStack stack` and the stack identity rides via
`floaterTopLeft` and `wings`).

The game's `startBoardCardDrag` constructs one of these and
assembles a `Dragging` from it; the eventual puzzle drag
handler can construct the same shape and assemble its own
state-machine variant from it.

Caveat: `Point`, `PathFrame`, `GesturePoint` currently still
live in `Main.State`. Moving them to a neutral location is
its own follow-up; for now this type's transitive deps reach
into `Main.State` for those primitives. The decoupling that
matters today is "the type's NAME and shape are not in
`Main.State`," so a non-game caller can import
`Game.Drag.BoardCardDragStartInfo` directly without touching
the game's `Model` or `DragState` constructors.

-}
type alias BoardCardDragStartInfo =
    { cursor : Point
    , floaterTopLeft : Point
    , pathFrame : PathFrame
    , gesturePath : List GesturePoint
    , wings : List WingId
    , boardRect : Maybe GA.Rect
    , clickIntent : Maybe Int
    , originalCursor : Point
    }
