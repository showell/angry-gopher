module Lib.HandDragTypes exposing (HandCardDragInfo)

import Lib.Physics.WingOracle exposing (WingId)
import Lib.Point exposing (Point)
import Lib.Rules.Card exposing (Card)


type alias HandCardDragInfo =
    { card : Card
    , cursor : Point
    , floaterTopLeft : Point
    , wings : List WingId
    }
