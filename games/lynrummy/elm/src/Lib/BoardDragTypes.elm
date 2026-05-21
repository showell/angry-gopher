module Lib.BoardDragTypes exposing
    ( BoardCardDragInfo
    , PressPendingInfo
    )

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


{-| Quiet phase between pointerdown and either (a) cursor escape
→ whole-stack drag, or (b) long-press timer fire → isolate.
The `startTimeMs` echo is race protection on the timer Msg —
a stale fire from a prior press lands here with a mismatched
stamp and gets discarded.
-}
type alias PressPendingInfo =
    { stack : CardStack
    , cardIndex : Int
    , originalCursor : Point
    , startTimeMs : Int
    , board : List CardStack
    }
