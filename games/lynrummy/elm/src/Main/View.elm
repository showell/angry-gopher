module Main.View exposing
    ( statusForCompleteTurn
    , view
    )

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
import Game.Game exposing (CompleteTurnOutcome, GameState)
import Game.Hand exposing (Hand)
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.Rules.Card exposing (Card)
import Game.View as View
import Html exposing (Html, div)
import Html.Attributes exposing (href, style)
import Html.Events as Events
import Game.BoardView as BoardView
import Game.Drag as Drag
import Game.Popup as Popup
import Main.Gesture as Gesture
import Main.Msg exposing (Msg(..))
import Game.Status exposing (StatusKind(..), StatusMessage)
import Main.State
    exposing
        ( Model
        , ReplayAnimationState(..)
        , ReplayState
        , canUndoThisTurn
        )



-- CEREMONY HELPERS


statusForCompleteTurn : Result outcome CompleteTurnOutcome -> StatusMessage
statusForCompleteTurn outcome =
    case outcome of
        Ok o ->
            case o.result of
                Success ->
                    { text = "Turn complete. Board is growing!", kind = Celebrate }

                SuccessButNeedsCards ->
                    { text = "Turn complete, but you didn't play any cards.", kind = Inform }

                SuccessAsVictor ->
                    { text = "Hand emptied — victor!", kind = Celebrate }

                SuccessWithHandEmptied ->
                    { text = "Hand emptied — nice.", kind = Celebrate }

                Failure ->
                    { text = "Board isn't clean — tidy up before ending the turn.", kind = Scold }

        Err _ ->
            { text = "Couldn't reach the server to complete the turn.", kind = Scold }


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
            [ viewStatusBar model.status ]
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
            [ boardColumn model ]
        , Popup.viewPopup PopupOk
            (case model.replayState of
                Just _ ->
                    Nothing

                Nothing ->
                    model.popup
            )
        ]



-- STATUS BAR


viewStatusBar : StatusMessage -> Html Msg
viewStatusBar status =
    let
        color =
            case status.kind of
                Inform ->
                    "#31708f"

                Celebrate ->
                    "green"

                Scold ->
                    "red"
    in
    div
        [ style "padding" "6px 20px"
        , style "font-size" "15px"
        , style "color" color
        , style "border-bottom" "1px solid #eee"
        , style "white-space" "pre-wrap"
        ]
        [ Html.text status.text ]



-- LEFT SIDEBAR


{-| The left column of the play surface. Shared chrome (fixed
width, right border, padding) wraps one of two interior
layouts:

  - `playerHands` — the main app's full hand-and-score surface
    with per-player rows + turn controls.
  - `puzzleControls` — the Puzzles gallery's stripped-down
    vertical button stack (Hint / Let agent play / replay).
    Puzzles are board-only, so everything in `playerHands`
    is irrelevant there.

-}
type alias PlayerPanelInfo =
    { gameState : GameState
    , drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    , replay : Maybe ReplayState
    }


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


leftSidebar : Model -> Html Msg
leftSidebar model =
    let
        info =
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
    in
    div
        [ style "min-width" "240px"
        , style "padding-right" "20px"
        , style "border-right" "1px gray solid"
        ]
        (playerHands info)


playerHands : PlayerPanelInfo -> List (Html Msg)
playerHands info =
    let
        activeInfo : ActivePlayerInfo
        activeInfo =
            { drag = info.drag
            , hintedCards = info.hintedCards
            , canUndo = info.canUndo
            , replay = info.replay
            }

        renderRow idx hand =
            if idx == info.gameState.activePlayerIndex then
                viewActivePlayerRow activeInfo idx hand

            else
                viewInactivePlayerRow idx hand
    in
    (div
        [ style "color" "#666"
        , style "font-size" "13px"
        , style "margin-top" "12px"
        ]
        [ Html.text ("Turn " ++ String.fromInt (info.gameState.turnIndex + 1)) ]
        :: List.indexedMap renderRow info.gameState.hands
    )
        ++ [ deckRemainingLine (List.length info.gameState.deck) ]


deckRemainingLine : Int -> Html Msg
deckRemainingLine deckCount =
    div
        [ style "color" "#666"
        , style "font-size" "13px"
        , style "margin-top" "8px"
        ]
        [ Html.text ("Deck: " ++ String.fromInt deckCount ++ " cards left") ]


type alias ActivePlayerInfo =
    { drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    , replay : Maybe ReplayState
    }


viewActivePlayerRow : ActivePlayerInfo -> Int -> Hand -> Html Msg
viewActivePlayerRow info idx hand =
    playerRowShell { isActive = True, idx = idx }
        [ View.viewHandHeading
        , View.viewHand
            { attrsForCard = Gesture.handCardAttrs info.drag info.hintedCards }
            hand
        , viewTurnControls { canUndo = info.canUndo, replay = info.replay }
        ]


viewInactivePlayerRow : Int -> Hand -> Html Msg
viewInactivePlayerRow idx hand =
    playerRowShell { isActive = False, idx = idx }
        [ div
            [ style "color" "#888"
            , style "font-size" "13px"
            ]
            [ Html.text (String.fromInt (List.length hand.handCards) ++ " cards") ]
        ]


playerRowShell : { isActive : Bool, idx : Int } -> List (Html Msg) -> Html Msg
playerRowShell { isActive, idx } body =
    let
        nameSuffix =
            if isActive then
                " (your turn)"

            else
                ""

        nameColor =
            if isActive then
                View.navy

            else
                "#666"
    in
    div
        [ style "padding-bottom" "15px"
        , style "margin-bottom" "12px"
        , style "border-bottom" "1px #000080 solid"
        ]
        (div
            [ style "font-weight" "bold"
            , style "font-size" "16px"
            , style "color" nameColor
            , style "margin-top" "8px"
            ]
            [ Html.text ("Player " ++ String.fromInt (idx + 1) ++ nameSuffix) ]
            :: body
        )


viewTurnControls : { canUndo : Bool, replay : Maybe ReplayState } -> Html Msg
viewTurnControls { canUndo, replay } =
    div
        [ style "margin-top" "12px"
        , style "display" "flex"
        , style "gap" "8px"
        , style "flex-wrap" "wrap"
        ]
        [ gameButton "Complete turn" ClickCompleteTurn
        , (if canUndo then
            gameButton "Undo" ClickUndo

           else
            disabledGameButton "Undo"
          )
        , gameButton "Hint" ClickHint
        , viewReplayControl replay
        , gameLink "← Lobby" "/gopher/game-lobby"
        ]


{-| Replay button — Resume / Pause when a replay is in
progress, or "Instant replay" when not.
-}
viewReplayControl : Maybe ReplayState -> Html Msg
viewReplayControl maybeReplay =
    case maybeReplay of
        Just progress ->
            if progress.paused then
                gameButton "Resume" ClickReplayPauseToggle

            else
                gameButton "Pause" ClickReplayPauseToggle

        Nothing ->
            gameButton "Instant replay" ClickInstantReplay


gameLink : String -> String -> Html Msg
gameLink label url =
    Html.a
        [ href url
        , style "padding" "6px 12px"
        , style "font-size" "14px"
        , style "border" ("1px solid " ++ View.navy)
        , style "background" "white"
        , style "color" View.navy
        , style "border-radius" "3px"
        , style "cursor" "pointer"
        , style "text-decoration" "none"
        ]
        [ Html.text label ]


gameButton : String -> Msg -> Html Msg
gameButton label msg =
    Html.button
        [ Events.onClick msg
        , style "padding" "6px 12px"
        , style "font-size" "14px"
        , style "border" ("1px solid " ++ View.navy)
        , style "background" "white"
        , style "color" View.navy
        , style "border-radius" "3px"
        , style "cursor" "pointer"
        ]
        [ Html.text label ]


disabledGameButton : String -> Html Msg
disabledGameButton label =
    Html.button
        [ Html.Attributes.disabled True
        , style "padding" "6px 12px"
        , style "font-size" "14px"
        , style "border" "1px solid #bbb"
        , style "background" "#f5f5f5"
        , style "color" "#bbb"
        , style "border-radius" "3px"
        , style "cursor" "not-allowed"
        ]
        [ Html.text label ]



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
