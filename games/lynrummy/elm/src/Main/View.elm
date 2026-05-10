module Main.View exposing (view)

{-| The game-surface view layer — composes the top bar, status
bar, hand column, board column, drag overlay, and popup into
an **embeddable** 1100×700 div (`position: relative`). The
main app's Main.elm wraps this in a viewport-filling outer
shell; Puzzles' Puzzles.elm places it directly inside each
puzzle panel.

Plus the turn-ceremony helpers (`statusForCompleteTurn`,
`popupForCompleteTurn`) that produce the status/popup records
update writes into Model.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith;
rewritten as embeddable 2026-04-23
(REFACTOR\_EMBEDDABLE\_PLAY phase III).


## Visual structure

    Html (position: relative, 1100×700, embeddable)
    ├── viewStatusBar           // at (0, 0), ~32px tall
    ├── leftSidebar            // at (20, 100), 240px wide
    │   ├── playerHands         // main app: turn # + per-player rows + turn controls
    │   └── puzzleControls      // Puzzles: Hint / Let agent play / Replay
    ├── boardColumn             // at (boardViewportLeft, boardViewportTop)
    │   └── boardWithWings      // id = `boardDomIdFor model.gameId`
    │       ├── viewStackForBoard (×N)
    │       └── viewWingAt       (×M, during drag only)
    ├── draggedOverlay          // floating drag card (position: fixed)
    └── viewPopup               // modal ceremony (position: fixed)

The drag floater and popup stay `position: fixed` — they're
viewport-level overlays that work the same whether the view
is inside the main app's viewport shell or inside a lab
panel on a scrolling page.

Note: `boardViewportLeft/Top` name the DOCUMENTARY position
inside this embeddable frame. The drag floater and replay
synthesizer DOM-measure the board's LIVE rect per drag /
per replay-start. When the Play surface sits inside a lab
panel on a scrolling page, live measurement is what keeps
drag math honest.

-}

import Game.BoardView as BoardView
import Game.CardStack exposing (CardStack)
import Game.Drag as Drag
import Game.Physics.BoardGeometry as BoardGeometry
import Game.Physics.GestureArbitration as GA
import Game.PointerInput as PointerInput
import Game.Popup as Popup
import Game.Replay.HandDragAnimate as HandDragAnimate
import Game.Replay.ReplayState exposing (Phase(..), ReplayState)
import Game.Sidebar as Sidebar
import Game.Status as Status
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Main.Msg exposing (Msg(..))
import Main.State
    exposing
        ( Model
        , canUndoThisTurn
        )



-- TOP-LEVEL VIEW


view : Model -> Html Msg
view model =
    -- Embeddable container. `position: relative` makes this div
    -- the positioning context for its absolute-positioned
    -- children (top-bar, status-bar, hand column, board column).
    -- Host wraps this (Main.elm wraps in a viewport-filling
    -- shell for the main app; Puzzles.elm places it inside a
    -- puzzle card). The drag floater and popup stay
    -- `position: fixed` since they're viewport-level overlays
    -- — consistent across hosts.
    --
    -- Fixed width/height give absolute children a well-defined
    -- frame and prevent the div from collapsing in normal flow.
    div
        [ style "font-family" "system-ui, sans-serif"
        , style "position" "relative"
        , style "width" "1100px"
        , style "height" "700px"
        , style "overflow" "hidden"
        , style "background" "#f4f4ec"
        ]
        [ div
            [ style "position" "absolute"
            , style "top" "0"
            , style "left" "0"
            , style "right" "0"
            ]
            [ Status.viewStatusBar model.status ]
        , div
            [ style "position" "absolute"
            , style "top" (String.fromInt BoardGeometry.boardViewportTop ++ "px")
            , style "left" "20px"
            , style "width" (String.fromInt (BoardGeometry.boardViewportLeft - 40) ++ "px")
            ]
            [ Sidebar.leftSidebar (sidebarInfo model) ]
        , div
            [ style "position" "absolute"
            , style "top" (String.fromInt BoardGeometry.boardViewportTop ++ "px")
            , style "left" (String.fromInt BoardGeometry.boardViewportLeft ++ "px")
            ]
            [ BoardView.boardColumn (boardColumnInput model) ]
        , Popup.viewPopup PopupOk model.popup
        ]



-- LEFT SIDEBAR
--
-- Implementation lives in `Game.Sidebar`. View only builds
-- the `PlayerPanelInfo` from Model and hands it off.
--
-- During Instant Replay, the sidebar + board are sourced
-- from `model.replayState`'s evolving `gameState`. The live
-- `model.gameState` is preserved untouched behind the scenes
-- and snaps back when `ReplayCompleted` clears `replayState`.


sidebarInfo : Model -> Sidebar.PlayerPanelInfo
sidebarInfo model =
    case model.replayState of
        Just rs ->
            { gameState = rs.gameState
            , drag = replayDrag rs
            , hintedCards = []
            , canUndo = False
            , replay = Just { paused = rs.paused }
            }

        Nothing ->
            { gameState = model.gameState
            , drag = model.drag
            , hintedCards = model.hintedCards
            , canUndo = canUndoThisTurn model
            , replay = Nothing
            }


boardColumnInput :
    Model
    ->
        { board : List CardStack
        , boardRect : Maybe GA.Rect
        , drag : Drag.DragState
        , gameId : String
        , cardMouseDown : CardStack -> Int -> List (Html.Attribute Msg)
        }
boardColumnInput model =
    let
        ( board, drag ) =
            case model.replayState of
                Just rs ->
                    ( rs.gameState.board, replayDrag rs )

                Nothing ->
                    ( model.gameState.board, model.drag )
    in
    { board = board
    , boardRect = model.boardRect
    , drag = drag
    , gameId = model.gameId
    , cardMouseDown = PointerInput.cardMouseDown MouseDownOnBoardCard
    }


{-| The drag state the View should render during a replay.
While `Animating`, surface the sub-machine's `dragInfo` so
the floater is visible. Other phases (Beat) are no-drag.
-}
replayDrag : ReplayState -> Drag.DragState
replayDrag rs =
    case rs.phase of
        AnimatingBoardAction dragState ->
            Drag.DraggingBoardCard dragState.dragInfo

        AnimatingHandAction handState ->
            case HandDragAnimate.dragInfo handState of
                Just info ->
                    Drag.DraggingHandCard info

                Nothing ->
                    -- AwaitingMeasurement — floater hasn't
                    -- appeared yet.
                    Drag.NotDragging

        Starting ->
            Drag.NotDragging

        InBeat _ ->
            Drag.NotDragging

        ExecutingAction _ ->
            Drag.NotDragging
