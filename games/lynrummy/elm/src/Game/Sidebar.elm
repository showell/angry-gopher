module Game.Sidebar exposing
    ( PlayerPanelInfo
    , leftSidebar
    )

{-| The left sidebar of the play surface. Owns the player-row
layout, turn controls, and the small button styles.
-}

import Game.Button as Button
import Game.Drag as Drag
import Game.Hand exposing (Hand)
import Game.Rules.Card exposing (Card)
import Game.Game exposing (GameState)
import Game.View as View
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Main.Gesture as Gesture
import Main.Msg exposing (Msg(..))


type alias PlayerPanelInfo =
    { gameState : GameState
    , drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
    }


type alias ActivePlayerInfo =
    { drag : Drag.DragState
    , hintedCards : List Card
    , canUndo : Bool
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
        , viewTurnControls { canUndo = info.canUndo }
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


viewTurnControls : { canUndo : Bool } -> Html Msg
viewTurnControls { canUndo } =
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
        , Button.button "Instant replay" ClickInstantReplay
        , Button.link "← Lobby" "/gopher/game-lobby"
        ]
