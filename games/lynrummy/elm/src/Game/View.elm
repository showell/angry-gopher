module Game.View exposing
    ( navy
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
import Game.PointerInput as PointerInput
import Game.Rules.Card as Card exposing (Card, Suit)
import Game.CardStack exposing (HandCard, HandCardState(..))
import Game.Hand as Hand exposing (Hand)
import Game.HandLayout as HandLayout
import Game.StackView as StackView
import Html exposing (Html, div, text)
import Html.Attributes exposing (id, style)
import Main.Msg exposing (Msg(..))



-- COLOR


navy : String
navy =
    "#000080"



-- HEADINGS


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

Per-card decoration is computed at the leaf
(`viewPlacedHandCard`) from three inputs: `handIsInteractive`
(false while any drag is in flight), `sourceCard` (the dim
overlay's target, if any), and `hintedCards` (hint highlight).
The mousedown handler attaches `Main.Msg.MouseDownOnHandCard`
directly — this module is full-game-specific.

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
