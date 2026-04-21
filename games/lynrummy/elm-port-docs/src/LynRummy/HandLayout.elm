module LynRummy.HandLayout exposing
    ( cardCenterInViewport
    , handCardDomId
    , handLeft
    , handTop
    , positionAt
    , suitRowHeight
    , suitRowIndex
    )

{-| Pinned hand layout.

Hand cards render at absolute positions computed from suit-row
index and within-row index. This makes the hand card's viewport
position a pure function of the hand's contents and the card
identity — no DOM lookup needed at replay time.

Python-originated hand plays don't carry hand-origin coords
(Python has no DOM, no hand layout), so the replay side uses
`cardCenterInViewport` to locate the hand card and animate a
drag from there to the pinned board target.

-}

import LynRummy.BoardGeometry as BG
import LynRummy.Card as Card exposing (Card, OriginDeck(..), Suit)
import LynRummy.CardStack exposing (HandCard)


{-| Viewport-left of the hand area. Aligned with the left of
the main content area (20px margin matches the `Main.View`
wrapper).
-}
handLeft : Int
handLeft =
    30


{-| Viewport-top of the hand area. Aligned roughly with the
board's top so the two columns sit at the same y.
-}
handTop : Int
handTop =
    100


{-| Vertical pitch between suit rows.
-}
suitRowHeight : Int
suitRowHeight =
    BG.cardHeight + 12


{-| Display order of suit rows, matching `LynRummy.View.viewHand`:
Heart on top, then Spade, Diamond, Club. Returns the 0-based
row index for a given suit, or -1 if unknown.
-}
suitRowIndex : Suit -> Int
suitRowIndex suit =
    let
        go i xs =
            case xs of
                [] ->
                    -1

                s :: rest ->
                    if s == suit then
                        i

                    else
                        go (i + 1) rest
    in
    go 0 Card.allSuits


{-| Viewport (x, y) of the center of a card at grid position
`{ row, col }`. Total function: both rendering and replay use
the same pinned math.
-}
positionAt : { row : Int, col : Int } -> { x : Int, y : Int }
positionAt { row, col } =
    { x = handLeft + col * BG.cardPitch + (BG.cardPitch // 2)
    , y = handTop + row * suitRowHeight + (BG.cardHeight // 2)
    }


{-| Viewport (x, y) of the center of the given card within the
current hand's rendered layout. Returns Nothing if the card
isn't in the hand.

Use at sites that don't already know where the card lives —
e.g., replay synthesis resolving a wire-action reference.
Rendering should iterate the hand and use `positionAt`
directly with the row/col it computed.
-}
cardCenterInViewport : Card -> List HandCard -> Maybe { x : Int, y : Int }
cardCenterInViewport card handCards =
    let
        row =
            suitRowIndex card.suit

        suitCards =
            handCards
                |> List.filter (\hc -> hc.card.suit == card.suit)
                |> List.sortBy (\hc -> Card.cardValueToInt hc.card.value)

        col =
            indexOf card suitCards
    in
    case ( row >= 0, col ) of
        ( True, Just c ) ->
            Just (positionAt { row = row, col = c })

        _ ->
            Nothing


{-| Stable DOM id for a hand card. Used by the replay
synthesizer to fetch the card's LIVE viewport rect via
`Browser.Dom.getElement`. Deck is disambiguated in the id so
the double-deck's two copies of (say) 7H each get a distinct
DOM node.
-}
handCardDomId : Card -> String
handCardDomId card =
    "hand-card-v"
        ++ String.fromInt (Card.cardValueToInt card.value)
        ++ "-s"
        ++ String.fromInt (Card.suitToInt card.suit)
        ++ "-d"
        ++ (case card.originDeck of
                DeckOne ->
                    "1"

                DeckTwo ->
                    "2"
           )


indexOf : Card -> List HandCard -> Maybe Int
indexOf target cards =
    let
        go i xs =
            case xs of
                [] ->
                    Nothing

                hc :: rest ->
                    if hc.card == target then
                        Just i

                    else
                        go (i + 1) rest
    in
    go 0 cards
