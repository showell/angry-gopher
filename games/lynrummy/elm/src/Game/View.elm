module Game.View exposing (view)

{-| The full-game view layer — composes the status bar, left
sidebar, board column, and popup into a 1100×700 div
(`position: relative`). Game.elm wraps this in a viewport-
filling outer shell.

`boardViewportLeft/Top` name the documentary position of the
board inside this frame; the drag floater and replay
synthesizer DOM-measure the board's live rect per drag /
per replay-start to stay honest under scrolling.
-}

import Lib.BoardView as BoardView
import Lib.CardStack as CardStack
import Lib.Drag as Drag exposing (DragState(..))
import Lib.Physics.BoardGeometry as BoardGeometry
import Lib.PointerInput as PointerInput
import Lib.Popup as Popup
import Lib.Animation.HandDragAnimate as HandDragAnimate
import Lib.Animation.Animate exposing (Phase(..), AnimationState)
import Lib.LeftSidebar as LeftSidebar
import Lib.Status as Status
import Lib.WingView as WingView
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Game.Msg exposing (Msg(..))
import Game.State
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
            case activeAnimation model of
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
         , case model.popup of
            Nothing ->
                Html.text ""

            Just { content, dismissMsg } ->
                Popup.viewPopup dismissMsg (Just content)
         ]
            ++ handFloaters
        )



-- LEFT SIDEBAR
--
-- Slice the Model into a `LeftSidebar.PlayerPanelInfo` and
-- hand it to `Lib.LeftSidebar`. During Instant Replay, the
-- sidebar's gameState comes from `model.replayState`'s
-- evolving copy; the live `model.gameState` is preserved
-- untouched and snaps back when `ReplayCompleted` clears
-- `replayState`.


leftSidebar : Model -> Html Msg
leftSidebar model =
    let
        drag =
            case activeAnimation model of
                Just rs ->
                    replayDrag rs

                Nothing ->
                    model.drag

        handIsInteractive =
            drag == NotDragging && not (humanInputLocked model)

        sourceCard =
            case drag of
                DraggingHandCard d ->
                    Just d.card

                _ ->
                    Nothing
    in
    case ( model.replayState, activeAnimation model ) of
        ( Just rs, _ ) ->
            LeftSidebar.view
                { gameState = rs.gameState
                , handIsInteractive = handIsInteractive
                , sourceCard = sourceCard
                , hintedCards = []
                , canUndo = False
                , controlsEnabled = False
                , replayControl =
                    if rs.paused then
                        LeftSidebar.ShowResume

                    else
                        LeftSidebar.ShowPause
                }

        ( Nothing, Just rs ) ->
            -- Agent-move animation in flight. Replay control
            -- stays at ShowReplay (the click is a no-op during
            -- agent turn — see the ClickInstantReplay arm).
            LeftSidebar.view
                { gameState = rs.gameState
                , handIsInteractive = handIsInteractive
                , sourceCard = sourceCard
                , hintedCards = []
                , canUndo = False
                , controlsEnabled = False
                , replayControl = LeftSidebar.ShowReplay
                }

        ( Nothing, Nothing ) ->
            LeftSidebar.view
                { gameState = model.gameState
                , handIsInteractive = handIsInteractive
                , sourceCard = sourceCard
                , hintedCards = model.hintedCards
                , canUndo = canUndoThisTurn model.actionLog
                , controlsEnabled = not model.agentTurnActive
                , replayControl = LeftSidebar.ShowReplay
                }



-- RIGHT SIDEBAR
--
-- Slice the Model into the inputs `Lib.BoardView.boardShell`
-- needs: a board (replay's or live), drag-derived per-stack
-- info (sourceStack, cardMouseDown), and drag-derived overlay
-- info (boardFloaters, wingsWithHover).


rightSidebar : Model -> Html Msg
rightSidebar model =
    let
        drag =
            case activeAnimation model of
                Just rs ->
                    replayDrag rs

                Nothing ->
                    model.drag

        board =
            case activeAnimation model of
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
            if humanInputLocked model then
                Nothing

            else
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



{-| Whichever AnimationState is in flight, if either. Instant
Replay and the real-time agent move share the same machinery
but live in distinct model fields; the view collapses them to
a single "is something animating right now?" for rendering.
-}
activeAnimation : Model -> Maybe AnimationState
activeAnimation model =
    case model.replayState of
        Just _ ->
            model.replayState

        Nothing ->
            model.agentMoveAnimationState


{-| True when the human shouldn't be able to interact: any
animation in flight (replay or agent), or the agent's turn is
active even between animations / under the end-of-turn modal.
The board/hand handlers consult this; the turn-controls buttons
consult `controlsEnabled` directly in `leftSidebar`.
-}
humanInputLocked : Model -> Bool
humanInputLocked model =
    activeAnimation model /= Nothing || model.agentTurnActive


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
