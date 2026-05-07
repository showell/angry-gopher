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

Mount choice is keyed off the drag variant:
`DraggingBoardCard` → board-shell child via `position: absolute`;
`DraggingHandCard` → viewport overlay via `position: fixed`.

A drag is rendered immediately on mousedown; the source stack
hides and the floater takes over at the same screen position.
Click-vs-drag arbitration is a mouseup-time outcome judgment,
not a state the View needs to know about.

-}

import Game.CardStack as CardStack exposing (CardStack)
import Game.Drag exposing (BoardCardDragInfo, DragState(..), HandCardDragInfo)
import Game.Physics.GestureArbitration as GA
import Game.Physics.WingOracle as WingOracle exposing (WingId)
import Game.View as View
import Html exposing (Html)
import Html.Attributes exposing (id, style)
import Main.Gesture as Gesture
import Main.Msg exposing (Msg)
import Main.State exposing (Model, boardDomIdFor)



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
                DraggingBoardCard d ->
                    List.map (viewWingForBoardDrag d) d.wings

                DraggingHandCard d ->
                    List.map (viewWingForHandDrag d model.boardRect) d.wings

                NotDragging ->
                    []

        boardOverlayNodes =
            case boardDragOverlay model.drag of
                Just node ->
                    [ node ]

                Nothing ->
                    []
    in
    stackNodes ++ wingNodes ++ boardOverlayNodes


viewStackForBoard : DragState -> CardStack -> Html Msg
viewStackForBoard drag stack =
    case drag of
        DraggingBoardCard d ->
            -- Hide the source stack — the floater renders in
            -- its place. At mousedown the floater is at
            -- exactly stack.loc, so the visual swap is a
            -- no-op; from there forward, the floater follows
            -- the cursor.
            if CardStack.isStacksEqual d.stack stack then
                Html.text ""

            else
                View.viewStack stack

        DraggingHandCard _ ->
            -- Hand-card drags don't affect any board stack's
            -- rendering; we still hide the stack-level
            -- mousedown handlers so the in-flight drag isn't
            -- re-triggered by stray events.
            View.viewStack stack

        NotDragging ->
            View.viewStackWithCardAttrs (Gesture.cardMouseDown stack) stack


viewWingForBoardDrag : BoardCardDragInfo -> WingId -> Html Msg
viewWingForBoardDrag d wing =
    let
        rect =
            WingOracle.wingBoardRect wing

        hovering =
            Gesture.floaterOverWingForBoard d == Just wing
    in
    renderWing rect hovering


viewWingForHandDrag : HandCardDragInfo -> Maybe GA.Rect -> WingId -> Html Msg
viewWingForHandDrag d boardRect wing =
    let
        rect =
            WingOracle.wingBoardRect wing

        hovering =
            Gesture.floaterOverWingForHand d boardRect == Just wing
    in
    renderWing rect hovering


renderWing : { left : Int, top : Int, width : Int, height : Int } -> Bool -> Html Msg
renderWing rect hovering =
    let
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
-}
draggedOverlay : Model -> Html Msg
draggedOverlay model =
    case model.drag of
        DraggingHandCard d ->
            renderHandFloater d [ style "position" "fixed" ]

        DraggingBoardCard _ ->
            Html.text ""

        NotDragging ->
            Html.text ""


{-| Board-frame drag overlay: a DOM child of the board shell
(which is `position: relative`) with `position: absolute` and
board-frame top/left. Renders intra-board drags.
-}
boardDragOverlay : DragState -> Maybe (Html Msg)
boardDragOverlay drag =
    case drag of
        DraggingBoardCard d ->
            Just (renderBoardFloater d [ style "position" "absolute" ])

        DraggingHandCard _ ->
            Nothing

        NotDragging ->
            Nothing


renderBoardFloater : BoardCardDragInfo -> List (Html.Attribute Msg) -> Html Msg
renderBoardFloater d positioningAttrs =
    View.viewStackWithAttrs (floatingAttrs d.floaterTopLeft positioningAttrs) d.stack


renderHandFloater : HandCardDragInfo -> List (Html.Attribute Msg) -> Html Msg
renderHandFloater d positioningAttrs =
    View.viewCardWithAttrs
        (floatingAttrs d.floaterTopLeft positioningAttrs
            ++ [ style "background-color" "white" ]
        )
        d.card


floatingAttrs : { x : Int, y : Int } -> List (Html.Attribute Msg) -> List (Html.Attribute Msg)
floatingAttrs floaterTopLeft positioningAttrs =
    positioningAttrs
        ++ [ style "top" (String.fromInt floaterTopLeft.y ++ "px")
           , style "left" (String.fromInt floaterTopLeft.x ++ "px")
           , style "pointer-events" "none"
           , style "z-index" "1000"
           ]
