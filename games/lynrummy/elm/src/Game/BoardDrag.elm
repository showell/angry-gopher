module Game.BoardDrag exposing (BoardCardDragInfo)

{-| Per-side home for board-card drags. First step: just the
type. Functions (`resolveBoardOutcome`, `applyBoardOutcome`,
the per-side `handleMouseUp` body) will follow.

`Game.Drag` re-exposes `BoardCardDragInfo` so existing
`import Game.Drag exposing (BoardCardDragInfo)` callers keep
working unchanged.

-}

import Game.CardStack exposing (BoardLocation, CardStack)
import Game.Physics.WingOracle exposing (WingId)
import Main.Types exposing (GesturePoint, Point)


type alias BoardCardDragInfo =
    { stack : CardStack
    , cardIndex : Int
    , originalCursor : Point
    , cursor : Point
    , floaterTopLeft : BoardLocation
    , gesturePath : List GesturePoint
    , wings : List WingId
    }
