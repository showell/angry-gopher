module Game.Drag exposing
    ( BoardCardDragInfo
    , DragSource(..)
    , DragState(..)
    , HandCardDragInfo
    , setFloaterTopLeft
    )

{-| Drag state types — the live shape of a board-card or hand-
card drag in flight.

Two variants, one per source kind. No `Maybe` fields. The
variant tag IS the discriminator; pattern-matching on it
gives every site only the data relevant to its kind.

`BoardCardDragInfo` always carries `cardIndex` and
`originalCursor`. At mouseup the resolver decides Split
vs. drag by computing `distSquared(cursor, originalCursor)`
against a tight radius — the click-vs-drag question is a
mouseup-time outcome judgment, not a state machine.

`HandCardDragInfo` has no `cardIndex` (hand cards have no
Split semantic) and no `originalCursor` (no click-vs-drag
arbitration for hand drags). It also has no `gesturePath`:
hand-origin drag paths are never replayed from a captured
sequence — replay re-synthesizes them via live DOM
measurement, so capturing them would be dead weight.

-}

import Game.Physics.WingOracle exposing (WingId)
import Game.Rules.Card exposing (Card)
import Game.CardStack exposing (BoardLocation, CardStack)
import Main.Types exposing (GesturePoint, Point)


type DragState
    = NotDragging
    | DraggingBoardCard BoardCardDragInfo
    | DraggingHandCard HandCardDragInfo


type alias BoardCardDragInfo =
    { stack : CardStack
    , cardIndex : Int
    , originalCursor : Point
    , cursor : Point
    , floaterTopLeft : BoardLocation
    , gesturePath : List GesturePoint
    , wings : List WingId
    }


type alias HandCardDragInfo =
    { card : Card
    , cursor : Point
    , floaterTopLeft : Point
    , wings : List WingId
    }


{-| Identity of a drag's source (which board stack or hand
card was picked up). The live `DragState` already encodes this
in its variant tag, so live code never needs `DragSource`.

Kept alive specifically for the replay subsystem, which carries
the source identity through its FSM (Animating, AwaitingHandRect)
without holding a live drag state. Will be revisited.

-}
type DragSource
    = FromBoardStack CardStack
    | FromHandCard Card


{-| Patch a new floater position into whichever variant is
active. Used by the replay frame loop: `DragAnimation.step`
computes the next floater point (as a generic `Point` from
the interpolator), and we lift it into the variant's expected
shape — `BoardLocation` for board drags (which live in board
frame), `Point` for hand drags (still in viewport frame).
-}
setFloaterTopLeft : Point -> DragState -> DragState
setFloaterTopLeft point state =
    case state of
        NotDragging ->
            NotDragging

        DraggingBoardCard d ->
            DraggingBoardCard
                { d | floaterTopLeft = { left = point.x, top = point.y } }

        DraggingHandCard d ->
            DraggingHandCard { d | floaterTopLeft = point }
