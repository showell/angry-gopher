module Lib.BoardDragTypes exposing (BoardCardDragInfo)

import Lib.CardStack exposing (BoardLocation, CardStack)
import Lib.NonEmpty exposing (NonEmpty)
import Lib.Physics.WingOracle exposing (WingId)
import Lib.Point exposing (Point)
import Lib.TimeLoc exposing (TimeLoc)


type alias BoardCardDragInfo =
    { stack : CardStack
    , cardIndex : Int
    , originalCursor : Point
    , cursor : Point
    , floaterTopLeft : BoardLocation
    , boardPath : NonEmpty TimeLoc
    , wings : List WingId
    }
