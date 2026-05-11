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
import Game.Rules.Card as Card exposing (Card, Suit)
import Game.CardStack exposing (HandCard, HandCardState(..))
import Game.Hand as Hand exposing (Hand)
import Game.HandLayout as HandLayout
import Game.StackView as StackView
import Html exposing (Html, div, text)
import Html.Attributes exposing (id, style)



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

Per-card decoration is computed at the leaf (`viewPlacedHandCard`)
from three orthogonal inputs threaded through `config`: source
card (for opacity dim), mousedown builder (for pointer events),
and hinted-cards list (for hint highlight).

-}
viewHand :
    { sourceCard : Maybe Card
    , cardMouseDown : Maybe (HandCard -> List (Html.Attribute msg))
    , hintedCards : List Card
    }
    -> Hand
    -> Html msg
viewHand config hand =
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
        (List.map (viewPlacedHandCard config) slots)


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
    { sourceCard : Maybe Card
    , cardMouseDown : Maybe (HandCard -> List (Html.Attribute msg))
    , hintedCards : List Card
    }
    -> { row : Int, col : Int, handCard : HandCard }
    -> Html msg
viewPlacedHandCard config slot =
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

        -- Three orthogonal per-card concerns: hint highlight
        -- (background override), source dim (opacity), pointer
        -- events (mousedown when idle, otherwise disabled).
        -- `pointer-events: none` for the source card falls out
        -- for free — a hand drag implies cardMouseDown is
        -- Nothing.
        hintAttrs =
            if List.any (\c -> c == hc.card) config.hintedCards then
                [ style "background-color" "lightgreen" ]

            else
                []

        sourceDimAttrs =
            if config.sourceCard == Just hc.card then
                [ style "opacity" "0.35" ]

            else
                []

        pointerAttrs =
            case config.cardMouseDown of
                Just attrs ->
                    attrs hc

                Nothing ->
                    [ style "pointer-events" "none" ]
    in
    StackView.viewCardWithAttrs
        (positionedAttrs ++ hintAttrs ++ sourceDimAttrs ++ pointerAttrs)
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
