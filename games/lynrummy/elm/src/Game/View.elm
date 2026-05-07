module Game.View exposing
    ( navy
    , viewBoardHeading
    , viewHand
    , viewHandHeading
    )

{-| Section headings, hand layout, and shared color constants.

Stack and card rendering moved to `Game.StackView`; wing
rendering and hover-detection moved to `Game.WingView`; the
board shell + drag-aware composition moved to
`Game.BoardView`. This module is the residual: hand rendering
(rows of suits) plus the heading helpers and the navy color
shared across surfaces.

-}

import Game.Physics.BoardGeometry as BG
import Game.Rules.Card as Card
import Game.CardStack exposing (HandCard, HandCardState(..))
import Game.Hand exposing (Hand)
import Game.HandLayout as HandLayout
import Game.StackView as StackView
import Html exposing (Html, div, text)
import Html.Attributes exposing (id, style)



-- COLOR


navy : String
navy =
    "#000080"



-- HEADINGS


viewBoardHeading : Html msg
viewBoardHeading =
    sectionHeading "Board"


viewHandHeading : Html msg
viewHandHeading =
    sectionHeading "Hand"


sectionHeading : String -> Html msg
sectionHeading label =
    div
        [ style "color" navy
        , style "font-weight" "bold"
        , style "font-size" "19px"
        , style "margin-top" "20px"
        ]
        [ text label ]



-- HAND


{-| Render a hand, sorted into rows of 4 suits in display
order (Heart, Spade, Diamond, Club), each row sorted by value
ascending. Empty suit rows are skipped. Faithful port of
`PhysicalHand.populate` in `game.ts:1589`.

`attrsForCard` supplies the mousedown handler (and any other
per-card attributes) keyed by hand-card index within the full
hand list.

-}
viewHand :
    { attrsForCard : HandCard -> List (Html.Attribute msg) }
    -> Hand
    -> Html msg
viewHand config hand =
    let
        rows =
            List.indexedMap
                (\rowIdx suit ->
                    hand.handCards
                        |> List.filter (\hc -> hc.card.suit == suit)
                        |> List.sortBy (\hc -> Card.cardValueToInt hc.card.value)
                        |> List.indexedMap
                            (\colIdx hc ->
                                { row = rowIdx
                                , col = colIdx
                                , handCard = hc
                                }
                            )
                )
                Card.allSuits
                |> List.concat

        containerHeight =
            4 * HandLayout.suitRowHeight
    in
    div
        [ style "position" "relative"
        , style "width" (String.fromInt (240 - 20) ++ "px")
        , style "height" (String.fromInt containerHeight ++ "px")
        ]
        (List.map (viewPlacedHandCard config) rows)


viewPlacedHandCard :
    { attrsForCard : HandCard -> List (Html.Attribute msg) }
    -> { row : Int, col : Int, handCard : HandCard }
    -> Html msg
viewPlacedHandCard config slot =
    let
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
            , style "background-color" (handCardBgColor slot.handCard)
            , id (HandLayout.handCardDomId slot.handCard.card)
            ]
    in
    StackView.viewCardWithAttrs
        (positionedAttrs ++ config.attrsForCard slot.handCard)
        slot.handCard.card


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
