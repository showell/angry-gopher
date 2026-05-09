module Game.BoardView exposing
    ( boardColumn
    , boardDomIdFor
    )

{-| The board widget — stacks, drag wings, and the
board-frame overlay for an in-flight intra-board drag.

`boardShellWith` (private) is the bare board shell (khaki
rectangle, `position: relative`, fixed 800×600). Used both
by the drag-aware `boardWithWings` and by the puzzle's
static `viewBoard`.

`boardWithWings` is the in-flow drag-aware board (shell with
stack children and, during a drag, wing targets and a
board-frame floater). The viewport-frame floater for
hand-origin drags lives in `Game.Drag.draggedOverlay`.

A drag is rendered immediately on mousedown; the source stack
hides and the floater takes over at the same screen position.
Click-vs-drag arbitration is a mouseup-time outcome judgment,
not a state the View needs to know about.

-}

import Game.CardStack as CardStack exposing (CardStack)
import Game.Drag as Drag exposing (DragState(..))
import Game.Physics.GestureArbitration as GA
import Game.StackView as StackView
import Game.View as View exposing (navy)
import Game.WingView as WingView
import Html exposing (Html, div)
import Html.Attributes exposing (id, style)



-- BOARD SHELL


{-| Board shell with extra attributes on the shell element
(e.g. an `id` for measurement, or mouseenter / mouseleave
handlers for tracking whether the cursor is over the board).
-}
boardShellWith : List (Html.Attribute msg) -> List (Html msg) -> Html msg
boardShellWith extraAttrs children =
    let
        -- Match the server's DEFAULT_BOARD_BOUNDS (800×600) exactly.
        -- Visible area = legal area, so users can't drop cards in
        -- what looks like the board but gets geometry-rejected at
        -- CompleteTurn.
        baseAttrs =
            [ style "background-color" "khaki"
            , style "border" ("1px solid " ++ navy)
            , style "border-radius" "15px"
            , style "position" "relative"
            , style "width" "800px"
            , style "height" "600px"
            , style "margin-top" "8px"
            ]
    in
    div (baseAttrs ++ extraAttrs) children



-- DRAG-AWARE BOARD


boardWithWings :
    { board : List CardStack
    , boardRect : Maybe GA.Rect
    , drag : DragState
    , gameId : String
    , cardMouseDown : CardStack -> Int -> List (Html.Attribute msg)
    }
    -> Html msg
boardWithWings { board, boardRect, drag, gameId, cardMouseDown } =
    boardShellWith
        [ id (boardDomIdFor gameId) ]
        (boardChildren board boardRect drag cardMouseDown)


boardChildren :
    List CardStack
    -> Maybe GA.Rect
    -> DragState
    -> (CardStack -> Int -> List (Html.Attribute msg))
    -> List (Html msg)
boardChildren board maybeBoardRect drag cardMouseDown =
    let
        stackNodes =
            List.map (viewStackForBoard drag cardMouseDown) board

        wingNodes =
            WingView.getWingNodes drag maybeBoardRect

        boardOverlayNodes =
            getOverlayNodes drag
    in
    stackNodes ++ wingNodes ++ boardOverlayNodes


viewStackForBoard :
    DragState
    -> (CardStack -> Int -> List (Html.Attribute msg))
    -> CardStack
    -> Html msg
viewStackForBoard drag cardMouseDown stack =
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
                StackView.viewStack stack

        DraggingHandCard _ ->
            -- Hand-card drags don't affect any board stack's
            -- rendering; we still hide the stack-level
            -- mousedown handlers so the in-flight drag isn't
            -- re-triggered by stray events.
            StackView.viewStack stack

        NotDragging ->
            StackView.viewStackWithCardAttrs (cardMouseDown stack) stack



-- DRAG OVERLAYS


{-| Board-frame drag overlay nodes: a DOM child of the board
shell (which is `position: relative`) with `position: absolute`
and board-frame top/left. Renders intra-board drags. Empty list
when no overlay applies — keeps the caller's concatenation
straightforward.

The viewport-frame counterpart for hand drags is
`Game.Drag.draggedOverlay`.
-}
getOverlayNodes : DragState -> List (Html msg)
getOverlayNodes drag =
    case drag of
        DraggingBoardCard d ->
            [ Drag.renderBoardFloater d [ style "position" "absolute" ] ]

        DraggingHandCard _ ->
            []

        NotDragging ->
            []



-- BOARD COLUMN
--
-- Top-level board column: heading + drag-aware board + the
-- viewport-frame floater overlay (for hand-card drags). One
-- entry-point for callers (Main.View, future puzzle host).
--
-- Msg-polymorphic: callers pass their own `cardMouseDown`
-- attr-builder so the board widget itself never needs to know
-- about the host's Msg constructors.


boardColumn :
    { board : List CardStack
    , boardRect : Maybe GA.Rect
    , drag : DragState
    , gameId : String
    , cardMouseDown : CardStack -> Int -> List (Html.Attribute msg)
    }
    -> Html msg
boardColumn input =
    div
        [ style "min-width" "800px" ]
        [ View.viewBoardHeading
        , boardWithWings input
        , Drag.draggedOverlay input.drag
        ]



-- DOM ID
--
-- CSS id of the board element. Lives here (the producer) so
-- Game.BoardView can be host-independent. Hosts pass `gameId =
-- "default"` (the main app's value); the parameter is
-- preserved so the DOM contract is unchanged in case multi-
-- Play hosting returns.


boardDomIdFor : String -> String
boardDomIdFor gameId =
    "lynrummy-board-" ++ gameId
