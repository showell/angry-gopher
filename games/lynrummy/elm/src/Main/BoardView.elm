module Main.BoardView exposing
    ( boardWithWings
    , draggedOverlay
    , viewBoard
    )

{-| The board widget — stacks, drag wings, and the dragged-
floater overlays.

`boardWithWings` is the in-flow board surface (a
`position: relative` shell with stack children and, during a
drag, wing targets and a board-frame floater).
`draggedOverlay` is the viewport-frame floater used for
hand-origin drags whose source is outside the board widget.

Both overlays share `renderDraggedFloater` — the same
"draw the dragged thing" code at two different mount frames.
Mount choice is `info.pathFrame`: `BoardFrame` → board-shell
child via `position: absolute`; `ViewportFrame` → viewport
overlay via `position: fixed`.

Extracted from `Main.View` 2026-05-06 as the first cut of the
post-puzzle-rip game-system disentangle. Today the input is
the parent `Model`; later phases will narrow that to a typed
snapshot so the same module can render a puzzle's board
without dragging in turn / hand / engine state.

-}

import Game.CardStack as CardStack exposing (CardStack)
import Game.Physics.WingOracle as WingOracle exposing (WingId)
import Game.View as View
import Html exposing (Html)
import Html.Attributes exposing (id, style)
import Main.Gesture as Gesture
import Main.Msg exposing (Msg)
import Main.State
    exposing
        ( DragContext
        , DragInfo
        , DragSource(..)
        , DragState(..)
        , Model
        , PathFrame(..)
        , boardDomIdFor
        )



-- STATIC RENDERING
--
-- The minimum surface to draw a board: a list of positioned
-- stacks on the standard board shell. No model, no drag
-- state, no gameId. Used by surfaces where there's nothing
-- to interact with (the puzzle V1, snapshot views, anything
-- that just wants to render a board image).
--
-- Polymorphic in `msg` so callers with their own Msg type
-- can use it without going through `Main.Msg`.


viewBoard : List CardStack -> Html msg
viewBoard stacks =
    View.boardShellWith [] (List.map View.viewStack stacks)



-- BOARD SHELL (drag-aware)


boardWithWings : Model -> Html Msg
boardWithWings model =
    View.boardShellWith [ id (boardDomIdFor model.gameId) ] (boardChildren model)


boardChildren : Model -> List (Html Msg)
boardChildren model =
    let
        stackNodes =
            List.map (viewStackForBoard model.drag) model.board

        wingNodes =
            case model.drag of
                Dragging info ctx _ ->
                    List.map (viewWingAt ctx info) ctx.wings

                NotDragging ->
                    []

        boardOverlayNodes =
            case boardDragOverlay model of
                Just node ->
                    [ node ]

                Nothing ->
                    []
    in
    stackNodes ++ wingNodes ++ boardOverlayNodes


viewStackForBoard : DragState -> CardStack -> Html Msg
viewStackForBoard drag stack =
    case drag of
        Dragging info _ arb ->
            case ( info.source, arb.clickIntent ) of
                ( FromBoardStack source, Nothing ) ->
                    -- Drag confirmed (click intent dropped).
                    -- Hide the source stack; the floater takes over.
                    if CardStack.isStacksEqual source stack then
                        Html.text ""

                    else
                        View.viewStack stack

                _ ->
                    -- Either a hand-card drag, or a board-source
                    -- still in the click-intent window (mousedown
                    -- without enough movement yet). In both cases
                    -- render the stack normally — no floater
                    -- visuals engage until drag is confirmed, so
                    -- clicks (splits) cause a single redraw on
                    -- release with no intermediate flash.
                    View.viewStackWithCardAttrs (Gesture.cardMouseDown stack) stack

        NotDragging ->
            View.viewStackWithCardAttrs (Gesture.cardMouseDown stack) stack


viewWingAt : DragContext -> DragInfo -> WingId -> Html Msg
viewWingAt ctx info wing =
    let
        rect =
            WingOracle.wingBoardRect wing

        hovering =
            Gesture.floaterOverWing ctx info == Just wing

        bgColor =
            if hovering then
                View.mergeableHover

            else
                View.mergeableGreen
    in
    View.viewWing
        { top = rect.top
        , left = rect.left
        , width = rect.width
        , bgColor = bgColor
        , extraAttrs = []
        }



-- DRAG OVERLAYS


{-| Viewport-frame drag overlay (`position: fixed`). Renders
hand-origin drags. Intra-board drags render via
`boardDragOverlay` inside the board shell.

While `clickIntent` is still alive (mousedown without
confirmed drag movement), the floater is suppressed so a
pure click doesn't briefly render a split-candidate floater
then discard it.

-}
draggedOverlay : Model -> Html Msg
draggedOverlay model =
    case model.drag of
        Dragging info _ arb ->
            if arb.clickIntent /= Nothing then
                Html.text ""

            else
                case info.pathFrame of
                    ViewportFrame ->
                        renderDraggedFloater info [ style "position" "fixed" ]

                    BoardFrame ->
                        Html.text ""

        NotDragging ->
            Html.text ""


{-| Board-frame drag overlay: a DOM child of the board shell
(which is `position: relative`) with `position: absolute` and
board-frame top/left. Renders intra-board drags.
-}
boardDragOverlay : Model -> Maybe (Html Msg)
boardDragOverlay model =
    case model.drag of
        Dragging info _ arb ->
            if arb.clickIntent /= Nothing then
                Nothing

            else
                case info.pathFrame of
                    BoardFrame ->
                        Just (renderDraggedFloater info [ style "position" "absolute" ])

                    ViewportFrame ->
                        Nothing

        NotDragging ->
            Nothing


{-| Shared floater renderer. Reads `info.floaterTopLeft`
directly into the CSS top/left; caller picks `fixed` (viewport)
vs `absolute` (board child). Frame of `floaterTopLeft` matches
the overlay's mount frame — no translation at render.
-}
renderDraggedFloater : DragInfo -> List (Html.Attribute Msg) -> Html Msg
renderDraggedFloater info positioningAttrs =
    let
        x =
            info.floaterTopLeft.x

        y =
            info.floaterTopLeft.y

        floatingAttrs =
            positioningAttrs
                ++ [ style "top" (String.fromInt y ++ "px")
                   , style "left" (String.fromInt x ++ "px")
                   , style "pointer-events" "none"
                   , style "z-index" "1000"
                   ]
    in
    case info.source of
        FromBoardStack source ->
            View.viewStackWithAttrs floatingAttrs source

        FromHandCard card ->
            View.viewCardWithAttrs
                (floatingAttrs ++ [ style "background-color" "white" ])
                card
