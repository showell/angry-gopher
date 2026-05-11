module Main.View exposing (view)

{-| The full-game view layer — composes the status bar, left
sidebar, board column, and popup into a 1100×700 div
(`position: relative`). Main.elm wraps this in a viewport-
filling outer shell.

`boardViewportLeft/Top` name the documentary position of the
board inside this frame; the drag floater and replay
synthesizer DOM-measure the board's live rect per drag /
per replay-start to stay honest under scrolling.
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
    -- `position: relative` so absolutely-positioned children
    -- (status bar, sidebar, board column) place inside this
    -- div. Drag floater and popup stay `position: fixed`
    -- (rendered inside `boardColumn` / here) — they're
    -- viewport-level overlays.
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
            , replayControl =
                if rs.paused then
                    Sidebar.ShowResume

                else
                    Sidebar.ShowPause
            }

        Nothing ->
            { gameState = model.gameState
            , drag = model.drag
            , hintedCards = model.hintedCards
            , canUndo = canUndoThisTurn model
            , replayControl = Sidebar.ShowReplay
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

        ActionCompleted ->
            Drag.NotDragging
