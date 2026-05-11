module Game.BoardView exposing
    ( boardDomIdFor
    , boardShell
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
import Game.Physics.WingOracle exposing (WingId)
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
    , drag : DragState
    , gameId : String
    , cardMouseDown : CardStack -> Int -> List (Html.Attribute msg)
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , boardFloaters : List (Html msg)
    }
    -> Html msg
boardShell { board, drag, gameId, cardMouseDown, wings, hoveredWing, boardFloaters } =
    let
        stackNodes =
            List.map (viewStackForBoard drag cardMouseDown) board

        wingNodes =
            List.map (WingView.renderWingWithHover hoveredWing) wings
    in
    div
        [ id (boardDomIdFor gameId)
        , style "background-color" "khaki"
        , style "border" ("1px solid " ++ navy)
        , style "border-radius" "15px"
        , style "position" "relative"
        , style "width" "800px"
        , style "min-width" "800px"
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
