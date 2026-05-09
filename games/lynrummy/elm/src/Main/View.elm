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

import Game.Physics.BoardGeometry as BoardGeometry
import Game.View as View
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Game.BoardView as BoardView
import Game.Drag as Drag
import Game.Popup as Popup
import Game.Sidebar as Sidebar
import Main.Msg exposing (Msg(..))
import Game.Status as Status
import Main.State
    exposing
        ( Model
        , ReplayAnimationState(..)
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
            [ boardColumn model ]
        , Popup.viewPopup PopupOk
            (case model.replayState of
                Just _ ->
                    Nothing

                Nothing ->
                    model.popup
            )
        ]



-- LEFT SIDEBAR
--
-- Implementation lives in `Game.Sidebar`. View only builds
-- the `PlayerPanelInfo` from Model (sourcing from replay
-- when active) and hands it off.


{-| Surface the drag the floater should render during replay.
The replay engine no longer keeps a parallel `drag` field on
ReplayState — the active drag (if any) lives inside the
AnimatingBoard / AnimatingHand variant of `rs.anim`. Other
phases imply NotDragging.
-}
dragFromAnim : ReplayAnimationState -> Drag.DragState
dragFromAnim anim =
    case anim of
        AnimatingBoard a ->
            Drag.DraggingBoardCard a.dragInfo

        AnimatingHand a ->
            Drag.DraggingHandCard a.dragInfo

        _ ->
            Drag.NotDragging


sidebarInfo : Model -> Sidebar.PlayerPanelInfo
sidebarInfo model =
    case model.replayState of
        Just rs ->
            { gameState = rs.gameState
            , drag = dragFromAnim rs.anim
            , hintedCards = []
            , canUndo = False
            , replay = Just rs
            }

        Nothing ->
            { gameState = model.gameState
            , drag = model.drag
            , hintedCards = model.hintedCards
            , canUndo = canUndoThisTurn model
            , replay = Nothing
            }



-- BOARD COLUMN


boardColumn : Model -> Html Msg
boardColumn model =
    let
        ( board, drag ) =
            case model.replayState of
                Just rs ->
                    ( rs.gameState.board, dragFromAnim rs.anim )

                Nothing ->
                    ( model.gameState.board, model.drag )
    in
    div
        [ style "min-width" "800px" ]
        [ View.viewBoardHeading
        , BoardView.boardWithWings
            { board = board
            , boardRect = model.boardRect
            , drag = drag
            , gameId = model.gameId
            }
        , Drag.draggedOverlay drag
        ]
