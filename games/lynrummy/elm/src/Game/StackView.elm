module Game.StackView exposing
    ( viewCardWithAttrs
    , viewStack
    , viewStackWithAttrs
    , viewStackWithCardAttrs
    )

{-| HTML rendering primitives for cards and card-stacks.

Stack-shape only — no drag state, no wings, no board shell.
Composers (`Game.BoardView`, `Game.LeftSidebar`) build on top
of these.

-}

import Game.Physics.BoardGeometry as BG
import Game.Rules.Card as Card exposing (Card, CardColor(..))
import Game.CardStack as CardStack exposing (BoardCard, BoardCardState(..), CardStack)
import Html exposing (Html, div, text)
import Html.Attributes exposing (style)


cardWidthPx : String
cardWidthPx =
    String.fromInt CardStack.cardWidth ++ "px"


cardHeightPx : String
cardHeightPx =
    String.fromInt BG.cardHeight ++ "px"



-- STACK


{-| Render a stack at its stored board location. No wings, no
drop targets — base physics only.
-}
viewStack : CardStack -> Html msg
viewStack stack =
    viewStackWithAttrs [] stack


{-| Same as `viewStack` but with extra attributes on the
**stack div** (e.g. a style override for opacity while the
stack is being dragged).
-}
viewStackWithAttrs : List (Html.Attribute msg) -> CardStack -> Html msg
viewStackWithAttrs extraAttrs stack =
    viewStackInternal extraAttrs (\_ -> []) stack


{-| Same as `viewStack` but with extra attributes on each
**individual card** (e.g. a `Html.Events.onMouseDown` for
click-or-drag initiation, indexed by the card's position in
the stack).
-}
viewStackWithCardAttrs :
    (Int -> List (Html.Attribute msg))
    -> CardStack
    -> Html msg
viewStackWithCardAttrs attrsForCard stack =
    viewStackInternal [] attrsForCard stack


viewStackInternal :
    List (Html.Attribute msg)
    -> (Int -> List (Html.Attribute msg))
    -> CardStack
    -> Html msg
viewStackInternal stackExtraAttrs attrsForCard stack =
    let
        isIncomplete =
            CardStack.isIncomplete stack

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
            List.indexedMap
                (\i bc -> viewBoardCardAt (attrsForCard i) i bc)
                stack.boardCards
    in
    div (baseAttrs ++ incompleteAttrs ++ stackExtraAttrs) cardNodes


viewBoardCardAt : List (Html.Attribute msg) -> Int -> BoardCard -> Html msg
viewBoardCardAt cardAttrs index bc =
    let
        marginAttrs =
            if index == 0 then
                []

            else
                [ style "margin-left" "2px" ]

        -- Colors stolen from TS game.ts: cyan for cards the current
        -- active player just placed this turn (FreshlyPlayed),
        -- lavender for cards the opponent placed last turn
        -- (FreshlyPlayedByLastPlayer). FirmlyOnBoard inherits the
        -- default white from viewPlayingCardWith.
        stateAttrs =
            case bc.state of
                FreshlyPlayed ->
                    [ style "background-color" "cyan" ]

                FreshlyPlayedByLastPlayer ->
                    [ style "background-color" "lavender" ]

                FirmlyOnBoard ->
                    []
    in
    viewPlayingCardWith (marginAttrs ++ stateAttrs ++ cardAttrs) bc.card



-- CARD


{-| Single playing card with extra attributes (mousedown
handler, margin overrides, background color).
-}
viewCardWithAttrs : List (Html.Attribute msg) -> Card -> Html msg
viewCardWithAttrs extraAttrs card =
    viewPlayingCardWith extraAttrs card


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
            , style "height" cardHeightPx
            , style "padding" "1px 1px 3px 1px"
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
