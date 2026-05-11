module Game.BoardView exposing
    ( boardColumn
    , boardDomIdFor
    )

{-| The board widget — khaki 800×600 rectangle, `position:
relative`, with stack children, wing targets, and caller-
supplied `boardFloaters`. The viewport-frame floater for
hand-origin drags is rendered at the host level (`position:
fixed` is DOM-position-independent).

A drag is rendered immediately on mousedown; the source stack
hides and the floater takes over at the same screen position.
Click-vs-drag arbitration is a mouseup-time outcome judgment,
not a state the View needs to know about.

-}

import Game.CardStack as CardStack exposing (CardStack)
import Game.Drag exposing (DragState(..))
import Game.Physics.GestureArbitration as GA
import Game.StackView as StackView
import Game.View exposing (navy)
import Game.WingView as WingView
import Html exposing (Html, div)
import Html.Attributes exposing (id, style)



-- BOARD SHELL


{-| The khaki 800×600 board rectangle with stack nodes, wing
targets, and caller-supplied `boardFloaters` inside. `position:
relative` so a `position: absolute` floater is positioned
against this div's coordinate frame.

The 800×600 size matches the server's `DEFAULT_BOARD_BOUNDS`
exactly: visible area = legal area, so users can't drop cards
in what looks like the board but gets geometry-rejected at
CompleteTurn.
-}
boardShell :
    { board : List CardStack
    , boardRect : Maybe GA.Rect
    , drag : DragState
    , gameId : String
    , cardMouseDown : CardStack -> Int -> List (Html.Attribute msg)
    , boardFloaters : List (Html msg)
    }
    -> Html msg
boardShell { board, boardRect, drag, gameId, cardMouseDown, boardFloaters } =
    let
        stackNodes =
            List.map (viewStackForBoard drag cardMouseDown) board

        wingNodes =
            WingView.getWingNodes drag boardRect
    in
    div
        [ id (boardDomIdFor gameId)
        , style "background-color" "khaki"
        , style "border" ("1px solid " ++ navy)
        , style "border-radius" "15px"
        , style "position" "relative"
        , style "width" "800px"
        , style "height" "600px"
        , style "margin-top" "8px"
        ]
        (stackNodes ++ wingNodes ++ boardFloaters)


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



-- BOARD COLUMN
--
-- Top-level board column: drag-aware board (board-frame stack
-- nodes + wing targets + caller-supplied `boardFloaters`).
--
-- `boardFloaters` is built and dispatched by the caller — the
-- board-frame floater is a `position: absolute` DOM child of
-- the (`position: relative`) board shell, so it has to be
-- threaded in alongside the stack nodes. The viewport-frame
-- hand floater is host-rendered too (also caller-side
-- dispatch), but doesn't need to thread through here —
-- `position: fixed` makes it DOM-position-independent.
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
    , boardFloaters : List (Html msg)
    }
    -> Html msg
boardColumn input =
    div
        [ style "min-width" "800px" ]
        [ boardShell input ]



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
