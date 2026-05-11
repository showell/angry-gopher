module Game.Drag exposing
    ( DragState(..)
    , renderBoardFloater
    , renderHandFloater
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
arbitration for hand drags).

The two render helpers (`renderBoardFloater`,
`renderHandFloater`) live alongside the types: a drag's
visual is intrinsic to what a drag IS, and they only ever
read fields the type already exposes. The dispatch on which
to render (or neither) lives in the host's view — by the
time we're rendering a floater, the host has earned that
knowledge. msg-polymorphic — the floater never emits its
own events.

-}

import Game.BoardDragTypes exposing (BoardCardDragInfo)
import Game.HandDragTypes exposing (HandCardDragInfo)
import Game.StackView as StackView
import Html exposing (Html)
import Html.Attributes exposing (style)


type DragState
    = NotDragging
    | DraggingBoardCard BoardCardDragInfo
    | DraggingHandCard HandCardDragInfo


-- RENDERING


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
