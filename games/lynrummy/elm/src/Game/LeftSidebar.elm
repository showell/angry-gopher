module Game.LeftSidebar exposing
    ( PlayerPanelInfo
    , ReplayControl(..)
    , view
    )

{-| The left sidebar of the play surface — player rows (active
hand widget + turn controls; inactive hand-count summary) plus
the deck-remaining line. Parallel to `Game.BoardView` on the
right side.

Full-game-specific: references `Main.Msg` constructors
directly. Puzzles never call into here.

-}

import Game.Button as Button
import Game.CardStack exposing (HandCard, HandCardState(..))
import Game.Colors as Colors
import Game.Game exposing (GameState)
import Game.Hand as Hand exposing (Hand)
import Game.HandLayout as HandLayout
import Game.Physics.BoardGeometry as BG
import Game.PointerInput as PointerInput
import Game.Rules.Card as Card exposing (Card, Suit)
import Game.StackView as StackView
import Html exposing (Html, div, text)
import Html.Attributes exposing (id, style)
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
    , handIsInteractive : Bool
    , sourceCard : Maybe Card
    , hintedCards : List Card
    , canUndo : Bool
    , replayControl : ReplayControl
    }



-- TOP-LEVEL VIEW


view : PlayerPanelInfo -> Html Msg
view info =
    div
        [ style "min-width" "240px"
        , style "padding-right" "20px"
        , style "border-right" "1px gray solid"
        ]
        (playerHands info)


playerHands : PlayerPanelInfo -> List (Html Msg)
playerHands info =
    (div
        [ style "color" "#666"
        , style "font-size" "13px"
        , style "margin-top" "12px"
        ]
        [ Html.text ("Turn " ++ String.fromInt (info.gameState.turnIndex + 1)) ]
        :: List.indexedMap
            (\idx hand ->
                if idx == info.gameState.activePlayerIndex then
                    div
                        [ style "padding-bottom" "15px"
                        , style "margin-bottom" "12px"
                        , style "border-bottom" "1px #000080 solid"
                        ]
                        [ div
                            [ style "font-weight" "bold"
                            , style "font-size" "16px"
                            , style "color" Colors.navy
                            , style "margin-top" "8px"
                            ]
                            [ Html.text ("Player " ++ String.fromInt (idx + 1) ++ " (your turn)") ]
                        , viewHandHeading
                        , viewHand info.handIsInteractive info.sourceCard info.hintedCards hand
                        , viewTurnControls { canUndo = info.canUndo, replayControl = info.replayControl }
                        ]

                else
                    div
                        [ style "padding-bottom" "15px"
                        , style "margin-bottom" "12px"
                        , style "border-bottom" "1px #000080 solid"
                        ]
                        [ div
                            [ style "font-weight" "bold"
                            , style "font-size" "16px"
                            , style "color" "#666"
                            , style "margin-top" "8px"
                            ]
                            [ Html.text ("Player " ++ String.fromInt (idx + 1)) ]
                        , div
                            [ style "color" "#888"
                            , style "font-size" "13px"
                            ]
                            [ Html.text (String.fromInt (List.length hand.handCards) ++ " cards") ]
                        ]
            )
            info.gameState.hands
    )
        ++ [ div
                [ style "color" "#666"
                , style "font-size" "13px"
                , style "margin-top" "8px"
                ]
                [ Html.text ("Deck: " ++ String.fromInt (List.length info.gameState.deck) ++ " cards left") ]
           ]



-- TURN CONTROLS


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



-- HAND


viewHandHeading : Html Msg
viewHandHeading =
    div
        [ style "color" Colors.navy
        , style "font-weight" "bold"
        , style "font-size" "19px"
        , style "margin-top" "20px"
        ]
        [ text "Hand" ]


{-| Render a hand, sorted into rows of 4 suits in display
order (Heart, Spade, Diamond, Club), each row sorted by value
ascending. Empty suit rows are skipped. Faithful port of
`PhysicalHand.populate` in `game.ts:1589`.

Per-card decoration is computed at the leaf
(`viewPlacedHandCard`) from three inputs: `handIsInteractive`
(false while any drag is in flight), `sourceCard` (the dim
overlay's target, if any), and `hintedCards` (hint highlight).

-}
viewHand :
    Bool
    -> Maybe Card
    -> List Card
    -> Hand
    -> Html Msg
viewHand handIsInteractive sourceCard hintedCards hand =
    let
        -- The hand DSL encoder consumes the same `sortIntoSuitRows`
        -- helper. Shared canonicalization keeps the on-screen
        -- layout and the DSL emission in lockstep.
        slots =
            Hand.sortIntoSuitRows hand
                |> List.concatMap
                    (\( suit, cards ) ->
                        List.indexedMap
                            (\colIdx hc ->
                                { row = suitToRowIdx suit
                                , col = colIdx
                                , handCard = hc
                                }
                            )
                            cards
                    )

        containerHeight =
            4 * HandLayout.suitRowHeight
    in
    div
        [ style "position" "relative"
        , style "width" (String.fromInt (240 - 20) ++ "px")
        , style "height" (String.fromInt containerHeight ++ "px")
        ]
        (List.map (viewPlacedHandCard handIsInteractive sourceCard hintedCards) slots)


suitToRowIdx : Suit -> Int
suitToRowIdx suit =
    case suit of
        Card.Heart ->
            0

        Card.Spade ->
            1

        Card.Diamond ->
            2

        Card.Club ->
            3


viewPlacedHandCard :
    Bool
    -> Maybe Card
    -> List Card
    -> { row : Int, col : Int, handCard : HandCard }
    -> Html Msg
viewPlacedHandCard handIsInteractive sourceCard hintedCards slot =
    let
        hc =
            slot.handCard

        center =
            HandLayout.positionAt { row = slot.row, col = slot.col }

        localLeft =
            center.x - HandLayout.handLeft - BG.cardPitch // 2

        localTop =
            center.y - HandLayout.handTop - BG.cardHeight // 2

        positionedAttrs =
            [ style "position" "absolute"
            , style "top" (String.fromInt localTop ++ "px")
            , style "left" (String.fromInt localLeft ++ "px")
            , style "cursor" "grab"
            , style "background-color" (handCardBgColor hc)
            , id (HandLayout.handCardDomId hc.card)
            ]

        hintAttrs =
            if List.any (\c -> c == hc.card) hintedCards then
                [ style "background-color" "lightgreen" ]

            else
                []

        sourceDimAttrs =
            if sourceCard == Just hc.card then
                [ style "opacity" "0.35" ]

            else
                []

        eventAttrs =
            if handIsInteractive then
                PointerInput.handCardMouseDown MouseDownOnHandCard hc

            else
                [ style "pointer-events" "none" ]
    in
    StackView.viewCardWithAttrs
        (positionedAttrs ++ hintAttrs ++ sourceDimAttrs ++ eventAttrs)
        hc.card


{-| Background color per HandCardState. Faithful port of
`PhysicalHandCard.update_state_styles` in `game.ts:1233`.
`is_hint` → "lightgreen" is omitted here; hints re-wire fresh
later.
-}
handCardBgColor : HandCard -> String
handCardBgColor hc =
    case hc.state of
        FreshlyDrawn ->
            "cyan"

        BackFromBoard ->
            "yellow"

        HandNormal ->
            "white"
