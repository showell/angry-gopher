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
    , gameId : String
    , sourceStack : Maybe CardStack
    , cardMouseDown : Maybe (CardStack -> Int -> List (Html.Attribute msg))
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , boardFloaters : List (Html msg)
    }
    -> Html msg
boardShell { board, gameId, sourceStack, cardMouseDown, wings, hoveredWing, boardFloaters } =
    let
        stackNodes =
            List.map (viewStackForBoard sourceStack cardMouseDown) board

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


{-| Per-stack rendering. Two independent facts:

  - `sourceStack` (Just iff a board-card drag is in flight) —
    if this stack is the source, hide it (the floater renders
    in its place).
  - `cardMouseDown` (Just iff no drag is in flight) — attach
    per-card mousedown handlers only when idle.

-}
viewStackForBoard :
    Maybe CardStack
    -> Maybe (CardStack -> Int -> List (Html.Attribute msg))
    -> CardStack
    -> Html msg
viewStackForBoard sourceStack cardMouseDown stack =
    let
        isSource =
            sourceStack
                |> Maybe.map (\src -> CardStack.isStacksEqual src stack)
                |> Maybe.withDefault False
    in
    if isSource then
        Html.text ""

    else
        case cardMouseDown of
            Just attrs ->
                StackView.viewStackWithCardAttrs (attrs stack) stack

            Nothing ->
                StackView.viewStack stack



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
