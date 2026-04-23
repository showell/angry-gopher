module Main.View exposing
    ( popupForCompleteTurn
    , statusForCompleteTurn
    , view
    )

{-| The entire view layer of the Elm client. One entry point
(`view`) that composes the top bar, status bar, hand column,
board column, drag overlay, and popup. Plus the turn-ceremony
helpers (`statusForCompleteTurn`, `popupForCompleteTurn`)
that produce the status/popup records update writes into
Model.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.
No I/O, no state transitions — every function here is
`_ -> Html Msg` or `_ -> StatusMessage / PopupContent`. The
only "action" is the Msg constructors emitted by user events.

## Visual structure

```
Html (position: fixed, covers viewport)
├── viewTopBar              // at viewport (0, 0), 32px tall
├── viewStatusBar           // at viewport (0, 32), 32px tall
├── handColumn gutter       // at viewport (20, 100), 240px wide
│   ├── turn #
│   └── viewPlayerRow × 2   // name + score + hand (if active) OR "N cards"
│       └── viewTurnControls  // Complete turn / Hint / Replay / Lobby
├── boardColumn             // at (boardViewportLeft, boardViewportTop)
│   └── boardWithWings
│       ├── viewStackForBoard (×N)
│       └── viewWingAt       (×M, during drag only)
├── draggedOverlay          // floating drag card (fixed-position)
└── viewPopup               // modal ceremony (suppressed during replay)
```

Note: boardViewportLeft/Top are the DOCUMENTARY values of
the board's viewport position. The drag floater and replay
synthesizer don't rely on them — they DOM-measure the board
rect live at replay time. See Main.claude.

-}

import Html exposing (Html, div)
import Html.Attributes exposing (href, id, style)
import Html.Events as Events
import Game.BoardActions exposing (Side(..))
import Game.BoardGeometry as BoardGeometry
import Game.CardStack as CardStack exposing (CardStack)
import Game.Hand exposing (Hand)
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.View as View
import Game.WingOracle as WingOracle exposing (WingId)
import Main.Gesture as Gesture
import Main.Msg exposing (Msg(..))
import Game.Game exposing (CompleteTurnOutcome)
import Main.State as State
    exposing
        ( DragInfo
        , DragSource(..)
        , DragState(..)
        , Model
        , PathFrame(..)
        , PopupContent
        , StatusKind(..)
        , StatusMessage
        , activeHand
        , boardDomIdFor
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


pluralize : Int -> String -> String
pluralize n word =
    String.fromInt n
        ++ " "
        ++ word
        ++ (if n == 1 then
                ""

            else
                "s"
           )



-- TOP-LEVEL VIEW


view : Model -> Html Msg
view model =
    -- Embeddable container. `position: relative` makes this div
    -- the positioning context for its absolute-positioned
    -- children (top-bar, status-bar, hand column, board column).
    -- Host wraps this (Main.elm wraps in a viewport-filling
    -- shell for the main app; Lab.elm places it inside a
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
            [ viewTopBar ]
        , div
            [ style "position" "absolute"
            , style "top" "32px"
            , style "left" "0"
            , style "right" "0"
            ]
            [ viewStatusBar model.status ]
        , div
            [ style "position" "absolute"
            , style "top" "100px"
            , style "left" "20px"
            , style "width" (String.fromInt (BoardGeometry.boardViewportLeft - 40) ++ "px")
            ]
            [ handColumn model ]
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



-- TOP BAR / STATUS BAR


viewTopBar : Html Msg
viewTopBar =
    div
        [ style "background-color" View.navy
        , style "color" "white"
        , style "text-align" "center"
        , style "padding" "6px"
        , style "font-size" "18px"
        ]
        [ Html.text "Welcome to Lyn Rummy! Have fun!" ]


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



-- HAND COLUMN


handColumn : Model -> Html Msg
handColumn model =
    div
        [ style "min-width" "240px"
        , style "padding-right" "20px"
        , style "border-right" "1px gray solid"
        ]
        (div
            [ style "color" "#666"
            , style "font-size" "13px"
            , style "margin-top" "12px"
            ]
            [ Html.text ("Turn " ++ String.fromInt (model.turnIndex + 1)) ]
            :: List.indexedMap (viewPlayerRow model) model.hands
        )


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


viewTurnControls : Model -> Html Msg
viewTurnControls model =
    let
        replayControl =
            case model.replay of
                Just progress ->
                    if progress.paused then
                        gameButton "Resume" ClickReplayPauseToggle

                    else
                        gameButton "Pause" ClickReplayPauseToggle

                Nothing ->
                    gameButton "Instant replay" ClickInstantReplay
    in
    div
        [ style "margin-top" "12px"
        , style "display" "flex"
        , style "gap" "8px"
        , style "flex-wrap" "wrap"
        ]
        [ gameButton "Complete turn" ClickCompleteTurn
        , gameButton "Hint" ClickHint
        , replayControl
        , gameLink "← Lobby" "/gopher/game-lobby"
        ]


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
            case info.source of
                FromBoardStack source ->
                    if CardStack.stacksEqual source stack then
                        Html.text ""

                    else
                        View.viewStack stack

                FromHandCard _ ->
                    View.viewStack stack

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


{-| Top-level drag overlay. Renders ONLY when the active drag's
path frame is ViewportFrame (hand-origin drags, or pre-
translation live-captured board drags). `position: fixed` over
the whole viewport. BoardFrame drags render via
`boardDragOverlay` inside the board-shell instead, where CSS
does the board→viewport math for free.
-}
draggedOverlay : Model -> Html Msg
draggedOverlay model =
    case model.drag of
        Dragging info ->
            case info.pathFrame of
                ViewportFrame ->
                    renderDraggedFloater model info [ style "position" "fixed" ]

                BoardFrame ->
                    Html.text ""

        NotDragging ->
            Html.text ""


{-| Board-level drag overlay. Renders as a DOM child of the
board shell (which is `position: relative`) with
`position: absolute` + board-frame coords. Active only when
the drag's path frame is BoardFrame (intra-board replay today;
intra-board live drags after the Tier 2 capture-time
translation).
-}
boardDragOverlay : Model -> Maybe (Html Msg)
boardDragOverlay model =
    case model.drag of
        Dragging info ->
            case info.pathFrame of
                BoardFrame ->
                    Just (renderDraggedFloater model info [ style "position" "absolute" ])

                ViewportFrame ->
                    Nothing

        NotDragging ->
            Nothing


{-| Shared floater renderer. The caller supplies the positioning
mode (`fixed` for viewport, `absolute` for board child); `top`
and `left` come from cursor − grabOffset regardless. The cursor
values are in whichever frame the overlay is mounted in.
-}
renderDraggedFloater : Model -> DragInfo -> List (Html.Attribute Msg) -> Html Msg
renderDraggedFloater _ info positioningAttrs =
    let
        x =
            info.cursor.x - info.grabOffset.x

        y =
            info.cursor.y - info.grabOffset.y

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



-- INTERNAL


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
