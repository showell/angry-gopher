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
    , viewStackWithCardAttrs
    , viewWing
    )

{-| HTML rendering for a LynRummy board and its cards.
Faithful port of the `render_*` pure-drawing functions in
`angry-cat/src/lyn_rummy/game/game.ts` (lines ~945–1180).

Primitives only. Drag state, wings, and dragged-stack overlays
are composed in `Main.elm` using these pieces.

-}

import Html exposing (Html, div, text)
import Html.Attributes exposing (id, style)
import LynRummy.BoardGeometry as BG
import LynRummy.Card as Card exposing (Card, CardColor(..), Suit)
import LynRummy.CardStack as CardStack exposing (BoardCard, BoardCardState(..), CardStack, HandCard, HandCardState(..))
import LynRummy.Hand exposing (Hand)
import LynRummy.HandLayout as HandLayout



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
        -- Match the server's DEFAULT_BOARD_BOUNDS (800×600) exactly.
        -- Visible area = legal area, so users can't drop cards in
        -- what looks like the board but gets geometry-rejected at
        -- CompleteTurn.
        baseAttrs =
            [ style "background-color" "khaki"
            , style "border" ("1px solid " ++ navy)
            , style "border-radius" "15px"
            , style "position" "relative"
            , style "width" "800px"
            , style "height" "600px"
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
        -- Build the (row, col, originalIndex, handCard) grid
        -- by iterating suits in display order and sorting each
        -- suit's cards by value, then pass row/col to
        -- `HandLayout.positionAt`.
        indexed =
            List.indexedMap Tuple.pair hand.handCards

        rows =
            List.indexedMap
                (\rowIdx suit ->
                    indexed
                        |> List.filter (\( _, hc ) -> hc.card.suit == suit)
                        |> List.sortBy (\( _, hc ) -> Card.cardValueToInt hc.card.value)
                        |> List.indexedMap
                            (\colIdx ( origIdx, hc ) ->
                                { row = rowIdx
                                , col = colIdx
                                , handIndex = origIdx
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
    { attrsForCard : Int -> HandCard -> List (Html.Attribute msg) }
    -> { row : Int, col : Int, handIndex : Int, handCard : HandCard }
    -> Html msg
viewPlacedHandCard config slot =
    let
        -- Center position (viewport), then convert to container-
        -- local top-left.
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
            , -- Stable DOM id so the replay synthesizer can
              -- fetch the card's LIVE viewport rect via
              -- Browser.Dom.getElement, rather than trusting
              -- pinned math.
              id (HandLayout.handCardDomId slot.handCard.card)
            ]
    in
    viewPlayingCardWith
        (positionedAttrs ++ config.attrsForCard slot.handIndex slot.handCard)
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
