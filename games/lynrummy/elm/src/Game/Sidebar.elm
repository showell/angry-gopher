module Game.Sidebar exposing
    ( PlayerPanelInfo
    , leftSidebar
    )

{-| The left sidebar of the play surface. Owns the player-row
layout, turn controls, and the small button styles. Caller
(Main.View) builds the `PlayerPanelInfo` from Model — during
replay, the same shape can be sourced from the replay's
gameState/drag, which is what makes this module reusable
across live-play and replay views.
-}

import Game.Drag as Drag
import Game.Hand exposing (Hand)
import Game.Rules.Card exposing (Card)
import Game.Game exposing (GameState)
import Game.View as View
import Html exposing (Html, div)
import Html.Attributes as Attr exposing (href, style)
import Html.Events as Events
import Main.Gesture as Gesture
import Main.Msg exposing (Msg(..))
import Main.State exposing (ReplayState)


type alias PlayerPanelInfo =
    { gameState : GameState
    , drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    , replay : Maybe ReplayState
    }


type alias ActivePlayerInfo =
    { drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    , replay : Maybe ReplayState
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
        [ Attr.disabled True
        , style "padding" "6px 12px"
        , style "font-size" "14px"
        , style "border" "1px solid #bbb"
        , style "background" "#f5f5f5"
        , style "color" "#bbb"
        , style "border-radius" "3px"
        , style "cursor" "not-allowed"
        ]
        [ Html.text label ]
