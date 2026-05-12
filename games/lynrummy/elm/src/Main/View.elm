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
import Game.CardStack as CardStack
import Game.Drag as Drag exposing (DragState(..))
import Game.Physics.BoardGeometry as BoardGeometry
import Game.PointerInput as PointerInput
import Game.Popup as Popup
import Game.Animation.HandDragAnimate as HandDragAnimate
import Game.Animation.Animate exposing (Phase(..), AnimationState)
import Game.LeftSidebar as LeftSidebar
import Game.Status as Status
import Game.WingView as WingView
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
    -- (status bar, sidebars) place inside this div. Hand
    -- floater stays `position: fixed` — a viewport-level
    -- overlay parallel to the popup.
    let
        drag =
            case model.replayState of
                Just rs ->
                    replayDrag rs

                Nothing ->
                    model.drag

        handFloaters =
            case drag of
                DraggingHandCard d ->
                    [ Drag.renderHandFloater d [ style "position" "fixed" ] ]

                _ ->
                    []
    in
    div
        [ style "font-family" "system-ui, sans-serif"
        , style "position" "relative"
        , style "width" "1100px"
        , style "height" "700px"
        , style "overflow" "hidden"
        , style "background" "#f4f4ec"
        ]
        ([ div
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
            [ leftSidebar model ]
         , div
            [ style "position" "absolute"
            , style "top" (String.fromInt BoardGeometry.boardViewportTop ++ "px")
            , style "left" (String.fromInt BoardGeometry.boardViewportLeft ++ "px")
            ]
            [ rightSidebar model ]
         , Popup.viewPopup PopupOk model.popup
         ]
            ++ handFloaters
        )



-- LEFT SIDEBAR
--
-- Slice the Model into a `LeftSidebar.PlayerPanelInfo` and
-- hand it to `Game.LeftSidebar`. During Instant Replay, the
-- sidebar's gameState comes from `model.replayState`'s
-- evolving copy; the live `model.gameState` is preserved
-- untouched and snaps back when `ReplayCompleted` clears
-- `replayState`.


leftSidebar : Model -> Html Msg
leftSidebar model =
    let
        drag =
            case model.replayState of
                Just rs ->
                    replayDrag rs

                Nothing ->
                    model.drag

        handIsInteractive =
            drag == NotDragging

        sourceCard =
            case drag of
                DraggingHandCard d ->
                    Just d.card

                _ ->
                    Nothing
    in
    case model.replayState of
        Just rs ->
            LeftSidebar.view
                { gameState = rs.gameState
                , handIsInteractive = handIsInteractive
                , sourceCard = sourceCard
                , hintedCards = []
                , canUndo = False
                , replayControl =
                    if rs.paused then
                        LeftSidebar.ShowResume

                    else
                        LeftSidebar.ShowPause
                }

        Nothing ->
            LeftSidebar.view
                { gameState = model.gameState
                , handIsInteractive = handIsInteractive
                , sourceCard = sourceCard
                , hintedCards = model.hintedCards
                , canUndo = canUndoThisTurn model.actionLog
                , replayControl = LeftSidebar.ShowReplay
                }



-- RIGHT SIDEBAR
--
-- Slice the Model into the inputs `Game.BoardView.boardShell`
-- needs: a board (replay's or live), drag-derived per-stack
-- info (sourceStack, cardMouseDown), and drag-derived overlay
-- info (boardFloaters, wingsWithHover).


rightSidebar : Model -> Html Msg
rightSidebar model =
    let
        drag =
            case model.replayState of
                Just rs ->
                    replayDrag rs

                Nothing ->
                    model.drag

        board =
            case model.replayState of
                Just rs ->
                    rs.gameState.board

                Nothing ->
                    model.gameState.board

        sourceStack =
            case drag of
                DraggingBoardCard d ->
                    Just d.stack

                _ ->
                    Nothing

        cardMouseDown =
            case drag of
                NotDragging ->
                    Just (PointerInput.cardMouseDown MouseDownOnBoardCard)

                _ ->
                    Nothing

        boardFloaters =
            case drag of
                DraggingBoardCard d ->
                    [ Drag.renderBoardFloater d [ style "position" "absolute" ] ]

                _ ->
                    []

        wings =
            case drag of
                DraggingBoardCard d ->
                    d.wings

                DraggingHandCard d ->
                    d.wings

                NotDragging ->
                    []

        -- Hover detection needs the floater in board frame.
        -- Board-card floater is already board-frame; hand-card
        -- floater is viewport-frame (`position: fixed`), so we
        -- subtract boardRect. Pre-rect-arrival → no hover.
        hoveredWing =
            case drag of
                DraggingBoardCard d ->
                    WingView.hoveredWing
                        d.floaterTopLeft
                        (CardStack.stackDisplayWidth d.stack)
                        d.wings

                DraggingHandCard d ->
                    case model.boardRect of
                        Just rect ->
                            let
                                floaterBoardLoc =
                                    { left = d.floaterTopLeft.x - rect.x
                                    , top = d.floaterTopLeft.y - rect.y
                                    }
                            in
                            WingView.hoveredWing floaterBoardLoc CardStack.stackPitch d.wings

                        Nothing ->
                            Nothing

                NotDragging ->
                    Nothing

        wingsWithHover =
            List.map (\w -> ( w, hoveredWing == Just w )) wings
    in
    BoardView.boardShell
        { board = board
        , gameId = model.gameId
        , sourceStack = sourceStack
        , cardMouseDown = cardMouseDown
        , wingsWithHover = wingsWithHover
        , boardFloaters = boardFloaters
        }



{-| The drag state the View should render during a replay.
While `Animating`, surface the sub-machine's `dragInfo` so
the floater is visible. Other phases (Beat) are no-drag.
-}
replayDrag : AnimationState -> Drag.DragState
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
