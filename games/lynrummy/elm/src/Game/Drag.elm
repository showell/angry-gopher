module Game.Drag exposing
    ( DragSource(..)
    , DragState(..)
    , draggedOverlay
    , renderBoardFloater
    , setFloaterTopLeft
    )

{-| Drag state types and the rendering of an in-flight drag.

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

The rendering helpers (`draggedOverlay`, `renderBoardFloater`,
`renderHandFloater`) live alongside the types: a drag's
visual is intrinsic to what a drag IS, and they only ever
read fields the type already exposes. msg-polymorphic — the
floater never emits its own events.

-}

import Game.BoardDrag exposing (BoardCardDragInfo)
import Game.CardStack exposing (CardStack)
import Game.HandDrag exposing (HandCardDragInfo)
import Game.Rules.Card exposing (Card)
import Game.StackView as StackView
import Html exposing (Html)
import Html.Attributes exposing (style)
import Main.Types exposing (Point)


type DragState
    = NotDragging
    | DraggingBoardCard BoardCardDragInfo
    | DraggingHandCard HandCardDragInfo


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



-- RENDERING


{-| Viewport-frame drag overlay (`position: fixed`). Renders
hand-origin drags only — board-frame floaters render as a
DOM child of the board shell via `renderBoardFloater`.
-}
draggedOverlay : DragState -> Html msg
draggedOverlay drag =
    case drag of
        DraggingHandCard d ->
            renderHandFloater d [ style "position" "fixed" ]

        DraggingBoardCard _ ->
            Html.text ""

        NotDragging ->
            Html.text ""


{-| Board-frame floater for an intra-board drag. Caller
typically passes `[ style "position" "absolute" ]` so the
floater positions itself relative to the (already
`position: relative`) board shell.
-}
renderBoardFloater : BoardCardDragInfo -> List (Html.Attribute msg) -> Html msg
renderBoardFloater d positioningAttrs =
    StackView.viewStackWithAttrs (floatingAttrs d.floaterTopLeft positioningAttrs) d.stack


{-| Viewport-frame floater for a hand-origin drag. The hand
floater is `position: fixed` (caller's responsibility), so
its `floaterTopLeft` is in viewport coords; we lift it into
`{ left, top }` shape for the shared positioning helper.
-}
renderHandFloater : HandCardDragInfo -> List (Html.Attribute msg) -> Html msg
renderHandFloater d positioningAttrs =
    StackView.viewCardWithAttrs
        (floatingAttrs
            { left = d.floaterTopLeft.x, top = d.floaterTopLeft.y }
            positioningAttrs
            ++ [ style "background-color" "white" ]
        )
        d.card


floatingAttrs :
    { left : Int, top : Int }
    -> List (Html.Attribute msg)
    -> List (Html.Attribute msg)
floatingAttrs floaterTopLeft positioningAttrs =
    positioningAttrs
        ++ [ style "top" (String.fromInt floaterTopLeft.top ++ "px")
           , style "left" (String.fromInt floaterTopLeft.left ++ "px")
           , style "pointer-events" "none"
           , style "z-index" "1000"
           ]
