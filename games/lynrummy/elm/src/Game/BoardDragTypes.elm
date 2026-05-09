module Game.BoardDragTypes exposing (BoardCardDragInfo)

import Game.CardStack exposing (BoardLocation, CardStack)
import Game.Physics.WingOracle exposing (WingId)
import Game.Point exposing (Point)
import Game.TimeLoc exposing (TimeLoc)


type alias BoardCardDragInfo =
    { stack : CardStack
    , cardIndex : Int
    , originalCursor : Point
    , cursor : Point
    , floaterTopLeft : BoardLocation
    , boardPath : List TimeLoc
    , wings : List WingId
    }
