module Game.Sidebar exposing
    ( PlayerPanelInfo
    , ReplayControl(..)
    , leftSidebar
    )

{-| The left sidebar of the play surface. Owns the player-row
layout, turn controls, and the small button styles.
-}

import Game.Button as Button
import Game.CardStack exposing (HandCard)
import Game.Drag as Drag exposing (DragState(..))
import Game.Hand exposing (Hand)
import Game.PointerInput as PointerInput
import Game.Rules.Card exposing (Card)
import Game.Game exposing (GameState)
import Game.View as View
import Html exposing (Html, Attribute, div)
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode
import Main.Msg exposing (Msg(..))


{-| Which replay-related button the sidebar should render. The
caller (`Main.View`) already inspects the live replay state and
hands one of three concrete states down — the sidebar never
sees a Maybe-bool.
-}
type ReplayControl
    = ShowReplay
    | ShowPause
    | ShowResume


type alias PlayerPanelInfo =
    { gameState : GameState
    , drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    , replayControl : ReplayControl
    }


type alias ActivePlayerInfo =
    { drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    , replayControl : ReplayControl
    }


leftSidebar : PlayerPanelInfo -> Html Msg
leftSidebar info =
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
            , replayControl = info.replayControl
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


viewActivePlayerRow : ActivePlayerInfo -> Int -> Hand -> Html Msg
viewActivePlayerRow info idx hand =
    playerRowShell { isActive = True, idx = idx }
        [ View.viewHandHeading
        , View.viewHand
            { attrsForCard = handCardAttrs info.drag info.hintedCards }
            hand
        , viewTurnControls { canUndo = info.canUndo, replayControl = info.replayControl }
        ]


{-| Per-hand-card attributes: hint highlight (light green if the
card identity is in `hintedCards`), mousedown hook when idle,
and dim + pointer-disable on the dragged source so the floater
is the only visible / interactive piece.
-}
handCardAttrs : DragState -> List Card -> HandCard -> List (Attribute Msg)
handCardAttrs drag hintedCards hc =
    let
        hintAttrs =
            if List.any (\c -> c == hc.card) hintedCards then
                [ style "background-color" "lightgreen" ]

            else
                []
    in
    hintAttrs
        ++ (case drag of
                NotDragging ->
                    [ Events.on "mousedown"
                        (Decode.map
                            (\p -> MouseDownOnHandCard { handCard = hc, point = p })
                            PointerInput.pointDecoder
                        )
                    ]

                DraggingHandCard d ->
                    if d.card == hc.card then
                        [ style "opacity" "0.35", style "pointer-events" "none" ]

                    else
                        [ style "pointer-events" "none" ]

                DraggingBoardCard _ ->
                    [ style "pointer-events" "none" ]
           )


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


viewTurnControls : { canUndo : Bool, replayControl : ReplayControl } -> Html Msg
viewTurnControls { canUndo, replayControl } =
    div
        [ style "margin-top" "12px"
        , style "display" "flex"
        , style "gap" "8px"
        , style "flex-wrap" "wrap"
        ]
        [ Button.button "Complete turn" ClickCompleteTurn
        , (if canUndo then
            Button.button "Undo" ClickUndo

           else
            Button.disabledButton "Undo"
          )
        , Button.button "Hint" ClickHint
        , viewReplayControl replayControl
        , Button.link "← Lobby" "/gopher/game-lobby"
        ]


viewReplayControl : ReplayControl -> Html Msg
viewReplayControl control =
    case control of
        ShowReplay ->
            Button.button "Instant replay" ClickInstantReplay

        ShowPause ->
            Button.button "Pause" ClickReplayPauseToggle

        ShowResume ->
            Button.button "Resume" ClickReplayPauseToggle
