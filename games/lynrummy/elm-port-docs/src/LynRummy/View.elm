module LynRummy.View exposing
    ( boardShell
    , cardHeightPx
    , mergeableGreen
    , mergeableHover
    , navy
    , viewBoardHeading
    , viewCard
    , viewStack
    , viewStackWithAttrs
    , viewWing
    )

{-| HTML rendering for a LynRummy board and its cards.
Faithful port of the `render_*` pure-drawing functions in
`angry-cat/src/lyn_rummy/game/game.ts` (lines ~945–1180).

Primitives only. Drag state, wings, and dragged-stack overlays
are composed in `Main.elm` using these pieces.

-}

import Html exposing (Html, div, text)
import Html.Attributes exposing (style)
import LynRummy.Card as Card exposing (Card, CardColor(..))
import LynRummy.CardStack as CardStack exposing (BoardCard, CardStack)



-- CONSTANTS


navy : String
navy =
    "#000080"


{-| Mergeable-wing background. `hsl(105, 72.70%, 87.10%)` in
`game.ts:1347` — a light pastel green. Faithful.
-}
mergeableGreen : String
mergeableGreen =
    "hsl(105, 72.70%, 87.10%)"


{-| Hover-over-wing background. Direct port of `"mauve"` at
`game.ts:1353`. The CSS `mauve` keyword isn't universal —
using the conventional CSS color.
-}
mergeableHover : String
mergeableHover =
    "#E0B0FF"


cardWidthPx : String
cardWidthPx =
    String.fromInt CardStack.cardWidth ++ "px"


cardHeightPx : String
cardHeightPx =
    "40px"



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


{-| Board shell — khaki play surface, navy border, relative
position. Callers supply all children (stacks, wings,
dragged-stack overlay).
-}
boardShell : List (Html msg) -> Html msg
boardShell children =
    div
        [ style "background-color" "khaki"
        , style "border" ("1px solid " ++ navy)
        , style "border-radius" "15px"
        , style "position" "relative"
        , style "height" "540px"
        , style "margin-top" "8px"
        ]
        children



-- STACK


{-| Render a stack at its stored board location. No wings, no
drop targets — base physics only.
-}
viewStack : CardStack -> Html msg
viewStack stack =
    viewStackWithAttrs [] stack


{-| Same as `viewStack` but with extra attributes (e.g. a
`Html.Events.onMouseDown` for drag initiation, or a style
override for opacity while the stack is being dragged).
-}
viewStackWithAttrs : List (Html.Attribute msg) -> CardStack -> Html msg
viewStackWithAttrs extraAttrs stack =
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
    div (baseAttrs ++ incompleteAttrs ++ extraAttrs) cardNodes


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



-- WING


{-| Render a wing at an absolute board position. Faithful port
of `render_wing` (`game.ts:984`) — transparent card-char
scaffolding gives the element its height — with
`style_as_mergeable` / `style_for_hover` applied at the call
site via `bgColor`.

Wings are top-level board children here, not nested inside the
stack div (unlike TS). This avoids the ugly "grow the wrapper
and compensate by shifting the stack left" pattern — stacks
stay stable, wings render next to them.

-}
viewWing :
    { top : Int
    , left : Int
    , width : Int
    , bgColor : String
    , extraAttrs : List (Html.Attribute msg)
    }
    -> Html msg
viewWing { top, left, width, bgColor, extraAttrs } =
    let
        base =
            [ style "position" "absolute"
            , style "top" (String.fromInt top ++ "px")
            , style "left" (String.fromInt left ++ "px")
            , style "width" (String.fromInt width ++ "px")
            , style "height" cardHeightPx
            , style "padding" "1px"
            , style "background-color" bgColor
            , style "user-select" "none"
            , style "text-align" "center"
            , style "vertical-align" "center"
            , style "font-size" "17px"
            , style "box-sizing" "border-box"
            , style "border" "1px solid transparent"
            ]
    in
    div (base ++ extraAttrs)
        [ div [ style "color" "transparent" ] [ text "+" ]
        , div [ style "color" "transparent" ] [ text "+" ]
        ]
