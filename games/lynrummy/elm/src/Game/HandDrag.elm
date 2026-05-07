module Game.HandDrag exposing (HandCardDragInfo)

{-| Per-side home for hand-card drags. First step: just the
type. Functions follow.

`Game.Drag` re-exposes `HandCardDragInfo` so existing
`import Game.Drag exposing (HandCardDragInfo)` callers keep
working unchanged.

-}

import Game.Physics.WingOracle exposing (WingId)
import Game.Rules.Card exposing (Card)
import Main.Types exposing (Point)


type alias HandCardDragInfo =
    { card : Card
    , cursor : Point
    , floaterTopLeft : Point
    , wings : List WingId
    }
