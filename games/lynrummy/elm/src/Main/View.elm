module Main.View exposing
    ( popupForCompleteTurn
    , statusForCompleteTurn
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

import Game.BoardGeometry as BoardGeometry
import Game.CardStack as CardStack exposing (CardStack)
import Game.Game exposing (CompleteTurnOutcome)
import Game.Hand exposing (Hand)
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.View as View
import Game.WingOracle as WingOracle exposing (WingId)
import Html exposing (Html, div)
import Html.Attributes exposing (href, id, style)
import Html.Events as Events
import Main.Gesture as Gesture
import Main.Msg exposing (Msg(..))
import Main.State
    exposing
        ( DragInfo
        , DragSource(..)
        , DragState(..)
        , Model
        , PathFrame(..)
        , PopupContent
        , StatusKind(..)
        , StatusMessage
        , boardDomIdFor
        )
import Main.Util exposing (listAt, pluralize)



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


{-| Picks the right character (Angry Cat / Oliver / Steve) and
writes the per-branch narration. Angry Cat scolds dirty boards,
Oliver sympathizes when no cards played, Steve celebrates
everything else. The "will receive" framing keeps the UI on
the pre-flip view until the user dismisses.
-}
popupForCompleteTurn : Result outcome CompleteTurnOutcome -> Maybe PopupContent
popupForCompleteTurn result =
    case result of
        Ok outcome ->
            Just (popupFromOutcome outcome)

        Err _ ->
            Just
                { admin = "Angry Cat"
                , body = "Couldn't reach the server to complete your turn."
                }


popupFromOutcome : CompleteTurnOutcome -> PopupContent
popupFromOutcome { result, turnScore, cardsDrawn } =
    case result of
        Failure ->
            { admin = "Angry Cat"
            , body =
                "The board is not clean!\n\n(nor is my litter box)\n\n"
                    ++ "Drag stacks back where they belong."
            }

        SuccessButNeedsCards ->
            { admin = "Oliver"
            , body =
                "Sorry you couldn't find a move.\n\n"
                    ++ "I'm going back to my nap!\n\n"
                    ++ "You scored "
                    ++ String.fromInt turnScore
                    ++ " points for your turn.\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn."
            }

        SuccessAsVictor ->
            { admin = "Steve"
            , body =
                "You are the first person to play all their cards!\n\n"
                    ++ "That earns you a 1500 point bonus.\n\n"
                    ++ "You got "
                    ++ String.fromInt turnScore
                    ++ " points for this turn.\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn.\n\n"
                    ++ "Keep winning!"
            }

        SuccessWithHandEmptied ->
            { admin = "Steve"
            , body =
                "Good job!\n\n"
                    ++ "You scored "
                    ++ String.fromInt turnScore
                    ++ " for this turn!\n\n"
                    ++ "We gave you a bonus for emptying your hand.\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn."
            }

        Success ->
            { admin = "Steve"
            , body =
                "The board is growing!\n\n"
                    ++ "You receive "
                    ++ String.fromInt turnScore
                    ++ " points for this turn!"
            }


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
        , draggedOverlay model
        , viewPopup
            (case model.replay of
                Just _ ->
                    Nothing

                Nothing ->
                    model.popup
            )
        ]



-- POPUP


{-| Cheapest-possible popup rendering: fixed-position backdrop
covering the viewport, centred white card with the admin's
name, the body text (pre-wrapped to preserve newlines), and a
single OK button. No focus trap, no ESC handler, no
click-outside dismiss — just the OK button. Good enough for
ceremony.
-}
viewPopup : Maybe PopupContent -> Html Msg
viewPopup maybePopup =
    case maybePopup of
        Nothing ->
            Html.text ""

        Just { admin, body } ->
            div
                [ style "position" "fixed"
                , style "inset" "0"
                , style "background-color" "rgba(0, 0, 0, 0.45)"
                , style "display" "flex"
                , style "align-items" "center"
                , style "justify-content" "center"
                , style "z-index" "2000"
                ]
                [ div
                    [ style "background" "white"
                    , style "border" ("1px solid " ++ View.navy)
                    , style "border-radius" "12px"
                    , style "padding" "24px 28px"
                    , style "max-width" "420px"
                    , style "box-shadow" "0 10px 30px rgba(0, 0, 0, 0.25)"
                    ]
                    [ div
                        [ style "font-weight" "bold"
                        , style "color" View.navy
                        , style "font-size" "15px"
                        , style "margin-bottom" "10px"
                        ]
                        [ Html.text admin ]
                    , Html.pre
                        [ style "font-family" "inherit"
                        , style "white-space" "pre-wrap"
                        , style "margin" "0 0 18px 0"
                        , style "font-size" "14px"
                        , style "line-height" "1.45"
                        ]
                        [ Html.text body ]
                    , Html.button
                        [ Events.onClick PopupOk
                        , style "background" View.navy
                        , style "color" "white"
                        , style "border" "none"
                        , style "padding" "8px 20px"
                        , style "border-radius" "4px"
                        , style "cursor" "pointer"
                        , style "font-size" "14px"
                        ]
                        [ Html.text "OK" ]
                    ]
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
leftSidebar : Model -> Html Msg
leftSidebar model =
    div
        [ style "min-width" "240px"
        , style "padding-right" "20px"
        , style "border-right" "1px gray solid"
        ]
        (if model.hideTurnControls then
            puzzleControls model

         else
            playerHands model
        )


playerHands : Model -> List (Html Msg)
playerHands model =
    (div
        [ style "color" "#666"
        , style "font-size" "13px"
        , style "margin-top" "12px"
        ]
        [ Html.text ("Turn " ++ String.fromInt (model.turnIndex + 1)) ]
        :: List.indexedMap (viewPlayerRow model) model.hands
    )
        ++ [ deckRemainingLine model ]


puzzleControls : Model -> List (Html Msg)
puzzleControls model =
    [ div
        [ style "padding-top" "12px"
        , style "display" "flex"
        , style "flex-direction" "column"
        , style "gap" "10px"
        , style "align-items" "stretch"
        ]
        [ gameButton "Hint" ClickHint
        , gameButton "Let agent play" ClickAgentPlay
        , viewReplayControl model
        ]
    ]


{-| Shows how many cards are left in the dealer's deck.
Helpful for gauging how far into the game the agent has
gotten / how long it's been sustaining itself.
-}
deckRemainingLine : Model -> Html Msg
deckRemainingLine model =
    div
        [ style "color" "#666"
        , style "font-size" "13px"
        , style "margin-top" "8px"
        ]
        [ Html.text
            ("Deck: "
                ++ String.fromInt (List.length model.deck)
                ++ " cards left"
            )
        ]


{-| One player's row — name + score + either full interactive
hand + turn controls (if active) or a card-count line (if not).
Always P1 above P2 regardless of who's active.
-}
viewPlayerRow : Model -> Int -> Hand -> Html Msg
viewPlayerRow model idx hand =
    let
        isActive =
            idx == model.activePlayerIndex

        playerName =
            "Player " ++ String.fromInt (idx + 1)

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

        playerTotal =
            case listAt idx model.scores of
                Just n ->
                    n

                Nothing ->
                    0

        turnDelta =
            model.score - model.turnStartBoardScore

        turnDeltaText =
            if turnDelta >= 0 then
                "+" ++ String.fromInt turnDelta

            else
                String.fromInt turnDelta

        turnDeltaLine =
            if isActive then
                [ div
                    [ style "color" "#555"
                    , style "font-size" "13px"
                    , style "margin-bottom" "6px"
                    ]
                    [ Html.text ("Turn: " ++ turnDeltaText) ]
                ]

            else
                []
    in
    div
        [ style "padding-bottom" "15px"
        , style "margin-bottom" "12px"
        , style "border-bottom" "1px #000080 solid"
        ]
        ([ div
            [ style "font-weight" "bold"
            , style "font-size" "16px"
            , style "color" nameColor
            , style "margin-top" "8px"
            ]
            [ Html.text (playerName ++ nameSuffix) ]
         , div
            [ style "color" "maroon"
            , style "margin-bottom" "4px"
            , style "margin-top" "4px"
            ]
            [ Html.text ("Score: " ++ String.fromInt playerTotal) ]
         ]
            ++ turnDeltaLine
            ++ (if isActive then
                    [ View.viewHandHeading
                    , View.viewHand { attrsForCard = Gesture.handCardAttrs model.drag model.hintedCards } hand
                    , viewTurnControls model
                    ]

                else
                    [ div
                        [ style "color" "#888"
                        , style "font-size" "13px"
                        ]
                        [ Html.text (String.fromInt (List.length hand.handCards) ++ " cards") ]
                    ]
               )
        )


{-| Main-app turn controls — Complete turn / Hint / Replay /
Lobby. The puzzle path uses `puzzleControls` instead and
never reaches this.
-}
viewTurnControls : Model -> Html Msg
viewTurnControls model =
    div
        [ style "margin-top" "12px"
        , style "display" "flex"
        , style "gap" "8px"
        , style "flex-wrap" "wrap"
        ]
        [ gameButton "Complete turn" ClickCompleteTurn
        , gameButton "Hint" ClickHint
        , viewReplayControl model
        , gameLink "← Lobby" "/gopher/game-lobby"
        ]


{-| Replay button — Resume / Pause when a replay is in
progress, or "Instant replay" when not. Used by both
`puzzleControls` and `viewTurnControls`.
-}
viewReplayControl : Model -> Html Msg
viewReplayControl model =
    case model.replay of
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



-- BOARD COLUMN


boardColumn : Model -> Html Msg
boardColumn model =
    div
        [ style "min-width" "800px" ]
        [ View.viewBoardHeading
        , boardWithWings model
        ]


boardWithWings : Model -> Html Msg
boardWithWings model =
    View.boardShellWith [ id (boardDomIdFor model.gameId) ] (boardChildren model)


boardChildren : Model -> List (Html Msg)
boardChildren model =
    let
        stackNodes =
            List.map (viewStackForBoard model.drag) model.board

        wingNodes =
            case model.drag of
                Dragging info ->
                    List.map (viewWingAt info) info.wings

                NotDragging ->
                    []

        boardOverlayNodes =
            case boardDragOverlay model of
                Just node ->
                    [ node ]

                Nothing ->
                    []
    in
    stackNodes ++ wingNodes ++ boardOverlayNodes


viewStackForBoard : DragState -> CardStack -> Html Msg
viewStackForBoard drag stack =
    case drag of
        Dragging info ->
            case ( info.source, info.clickIntent ) of
                ( FromBoardStack source, Nothing ) ->
                    -- Drag confirmed (click intent dropped).
                    -- Hide the source stack; the floater takes over.
                    if CardStack.isStacksEqual source stack then
                        Html.text ""

                    else
                        View.viewStack stack

                _ ->
                    -- Either a hand-card drag, or a board-source
                    -- still in the click-intent window (mousedown
                    -- without enough movement yet). In both cases
                    -- render the stack normally — no floater
                    -- visuals engage until drag is confirmed, so
                    -- clicks (splits) cause a single redraw on
                    -- release with no intermediate flash.
                    View.viewStackWithCardAttrs (Gesture.cardMouseDown stack) stack

        NotDragging ->
            View.viewStackWithCardAttrs (Gesture.cardMouseDown stack) stack


viewWingAt : DragInfo -> WingId -> Html Msg
viewWingAt info wing =
    let
        rect =
            WingOracle.wingBoardRect wing

        hovering =
            info.hoveredWing == Just wing

        bgColor =
            if hovering then
                View.mergeableHover

            else
                View.mergeableGreen
    in
    View.viewWing
        { top = rect.top
        , left = rect.left
        , width = rect.width
        , bgColor = bgColor
        , extraAttrs = []
        }


{-| Viewport-frame drag overlay (`position: fixed`). Renders
hand-origin drags. Intra-board drags render via
`boardDragOverlay` inside the board shell.

While `clickIntent` is still alive (mousedown without
confirmed drag movement), the floater is suppressed so a
pure click doesn't briefly render a split-candidate floater
then discard it.

-}
draggedOverlay : Model -> Html Msg
draggedOverlay model =
    case model.drag of
        Dragging info ->
            if info.clickIntent /= Nothing then
                Html.text ""

            else
                case info.pathFrame of
                    ViewportFrame ->
                        renderDraggedFloater info [ style "position" "fixed" ]

                    BoardFrame ->
                        Html.text ""

        NotDragging ->
            Html.text ""


{-| Board-frame drag overlay: a DOM child of the board shell
(which is `position: relative`) with `position: absolute` and
board-frame top/left. Renders intra-board drags.
-}
boardDragOverlay : Model -> Maybe (Html Msg)
boardDragOverlay model =
    case model.drag of
        Dragging info ->
            if info.clickIntent /= Nothing then
                Nothing

            else
                case info.pathFrame of
                    BoardFrame ->
                        Just (renderDraggedFloater info [ style "position" "absolute" ])

                    ViewportFrame ->
                        Nothing

        NotDragging ->
            Nothing


{-| Shared floater renderer. Reads `info.floaterTopLeft`
directly into the CSS top/left; caller picks `fixed` (viewport)
vs `absolute` (board child). Frame of `floaterTopLeft` matches
the overlay's mount frame — no translation at render.
-}
renderDraggedFloater : DragInfo -> List (Html.Attribute Msg) -> Html Msg
renderDraggedFloater info positioningAttrs =
    let
        x =
            info.floaterTopLeft.x

        y =
            info.floaterTopLeft.y

        floatingAttrs =
            positioningAttrs
                ++ [ style "top" (String.fromInt y ++ "px")
                   , style "left" (String.fromInt x ++ "px")
                   , style "pointer-events" "none"
                   , style "z-index" "1000"
                   ]
    in
    case info.source of
        FromBoardStack source ->
            View.viewStackWithAttrs floatingAttrs source

        FromHandCard card ->
            View.viewCardWithAttrs
                (floatingAttrs ++ [ style "background-color" "white" ])
                card
