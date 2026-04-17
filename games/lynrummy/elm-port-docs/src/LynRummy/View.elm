module LynRummy.View exposing
    ( boardShell
    , boardShellWith
    , cardHeightPx
    , mergeableGreen
    , mergeableHover
    , navy
    , viewBoardHeading
    , viewCard
    , viewCardWithAttrs
    , viewHand
    , viewHandHeading
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
import LynRummy.Card as Card exposing (Card, CardColor(..), Suit)
import LynRummy.CardStack as CardStack exposing (BoardCard, CardStack, HandCard, HandCardState(..))
import LynRummy.Hand exposing (Hand)



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



-- BOARD


{-| Board shell — khaki play surface, navy border, relative
position. Callers supply all children (stacks, wings,
dragged-stack overlay).
-}
boardShell : List (Html msg) -> Html msg
boardShell children =
    boardShellWith [] children


{-| Board shell with extra attributes on the shell element
(e.g. an `id` for measurement, or mouseenter / mouseleave
handlers for tracking whether the cursor is over the board).
-}
boardShellWith : List (Html.Attribute msg) -> List (Html msg) -> Html msg
boardShellWith extraAttrs children =
    let
        baseAttrs =
            [ style "background-color" "khaki"
            , style "border" ("1px solid " ++ navy)
            , style "border-radius" "15px"
            , style "position" "relative"
            , style "height" "540px"
            , style "margin-top" "8px"
            ]
    in
    div (baseAttrs ++ extraAttrs) children



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



-- HAND


{-| Render a hand, sorted into rows of 4 suits in display
order (Heart, Spade, Diamond, Club), each row sorted by value
ascending. Empty suit rows are skipped. Faithful port of
`PhysicalHand.populate` in `game.ts:1589`.

`attrsForCard` supplies the mousedown handler (and any other
per-card attributes) keyed by hand-card index within the full
hand list. We pass the index rather than the `HandCard` itself
so Main.elm can dispatch `MouseDownOnHandCard index` cleanly.

-}
viewHand :
    { attrsForCard : Int -> HandCard -> List (Html.Attribute msg) }
    -> Hand
    -> Html msg
viewHand config hand =
    let
        indexed =
            List.indexedMap Tuple.pair hand.handCards
    in
    div
        [ style "margin-top" "10px" ]
        (List.filterMap (viewSuitRow config indexed) Card.allSuits)


viewSuitRow :
    { attrsForCard : Int -> HandCard -> List (Html.Attribute msg) }
    -> List ( Int, HandCard )
    -> Suit
    -> Maybe (Html msg)
viewSuitRow config indexed suit =
    let
        suitCards =
            indexed
                |> List.filter (\( _, hc ) -> hc.card.suit == suit)
                |> List.sortBy (\( _, hc ) -> Card.cardValueToInt hc.card.value)
    in
    if List.isEmpty suitCards then
        Nothing

    else
        Just <|
            div
                [ style "padding-bottom" "10px" ]
                (List.map
                    (\( idx, hc ) -> viewHandCard (config.attrsForCard idx hc) hc)
                    suitCards
                )


viewHandCard : List (Html.Attribute msg) -> HandCard -> Html msg
viewHandCard extraAttrs hc =
    let
        bgColor =
            handCardBgColor hc

        handAttrs =
            [ style "margin" "3px"
            , style "cursor" "grab"
            , style "background-color" bgColor
            ]
    in
    viewPlayingCardWith (handAttrs ++ extraAttrs) hc.card


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
