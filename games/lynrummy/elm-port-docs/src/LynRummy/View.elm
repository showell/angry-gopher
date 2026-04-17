module LynRummy.View exposing
    ( viewBoard
    , viewBoardHeading
    , viewCard
    , viewStack
    )

{-| HTML rendering for a LynRummy board and its cards.
Faithful port of the `render_*` pure-drawing functions in
`angry-cat/src/lyn_rummy/game/game.ts` (lines ~945–1180).

First-pass coverage: card, stack, board, heading. Action
buttons, hand row, and drag-target styling are deferred.

-}

import Html exposing (Html, div, text)
import Html.Attributes as HA exposing (style)
import LynRummy.Card as Card exposing (Card, CardColor(..))
import LynRummy.CardStack as CardStack exposing (BoardCard, CardStack)



-- CONSTANTS


navy : String
navy =
    "#000080"


cardWidthPx : String
cardWidthPx =
    String.fromInt CardStack.cardWidth ++ "px"



-- HEADING


viewBoardHeading : Html msg
viewBoardHeading =
    div
        [ style "color" navy
        , style "font-weight" "bold"
        , style "font-size" "19px"
        , style "margin-top" "20px"
        ]
        [ text "Board" ]



-- BOARD


viewBoard : List CardStack -> Html msg
viewBoard stacks =
    div
        [ style "background-color" "khaki"
        , style "border" ("1px solid " ++ navy)
        , style "border-radius" "15px"
        , style "position" "relative"
        , style "height" "540px"
        , style "margin-top" "8px"
        ]
        (List.map viewStack stacks)



-- STACK


viewStack : CardStack -> Html msg
viewStack stack =
    let
        isIncomplete =
            CardStack.incomplete stack

        baseAttrs =
            [ style "user-select" "none"
            , style "position" "absolute"
            , style "top" (String.fromInt stack.loc.top ++ "px")
            , style "left" (String.fromInt stack.loc.left ++ "px")
            ]

        incompleteAttrs =
            if isIncomplete then
                [ style "border" "1px gray solid"
                , style "background-color" "gray"
                ]

            else
                []

        cardNodes =
            List.indexedMap viewBoardCardAt stack.boardCards
    in
    div (baseAttrs ++ incompleteAttrs)
        (viewWing :: cardNodes ++ [ viewWing ])


viewBoardCardAt : Int -> BoardCard -> Html msg
viewBoardCardAt index bc =
    let
        extra =
            if index == 0 then
                []

            else
                [ style "margin-left" "2px" ]
    in
    viewPlayingCardWith extra bc.card



-- CARD


{-| Single playing card. Exported as `viewCard` with no extras.
-}
viewCard : Card -> Html msg
viewCard card =
    viewPlayingCardWith [] card


viewPlayingCardWith : List (Html.Attribute msg) -> Card -> Html msg
viewPlayingCardWith extraAttrs card =
    let
        colorStr =
            case Card.cardColor card of
                Red ->
                    "red"

                Black ->
                    "black"

        baseAttrs =
            [ style "display" "inline-block"
            , style "height" "40px"
            , style "padding" "1px"
            , style "user-select" "none"
            , style "text-align" "center"
            , style "vertical-align" "center"
            , style "font-size" "17px"
            , style "color" colorStr
            , style "background-color" "white"
            , style "border" "1px blue solid"
            , style "width" cardWidthPx
            ]
    in
    div (baseAttrs ++ extraAttrs)
        [ viewCardChar (Card.valueDisplayStr card.value)
        , viewCardChar (Card.suitEmojiStr card.suit)
        ]


viewCardChar : String -> Html msg
viewCardChar c =
    div
        [ style "display" "block"
        , style "user-select" "none"
        ]
        [ text c ]



-- WING


{-| Invisible zero-width placeholder at each end of a stack.
Faithful to TS structure; will carry drop-target logic when
drag work arrives.
-}
viewWing : Html msg
viewWing =
    div
        [ style "background-color" "transparent"
        , style "display" "inline-block"
        , style "height" "40px"
        , style "padding" "1px"
        , style "user-select" "none"
        , style "text-align" "center"
        , style "vertical-align" "center"
        , style "font-size" "17px"
        , style "width" "0px"
        ]
        [ div [ style "display" "block", style "user-select" "none", style "color" "transparent" ] [ text "+" ]
        , div [ style "display" "block", style "user-select" "none", style "color" "transparent" ] [ text "+" ]
        ]
