module Game.HandDragTypes exposing (HandCardDragInfo)

import Game.Physics.WingOracle exposing (WingId)
import Game.Point exposing (Point)
import Game.Rules.Card exposing (Card)


type alias HandCardDragInfo =
    { card : Card
    , cursor : Point
    , floaterTopLeft : Point
    , wings : List WingId
    }
