module LynRummy.HandLayout exposing
    ( handCardDomId
    , handLeft
    , handTop
    , positionAt
    , suitRowHeight
    )

{-| Pinned hand layout.

Hand cards render at absolute positions computed from suit-row
index and within-row index. `View.elm` walks the hand, computes
`{ row, col }` for each card, and calls `positionAt` to place
the DOM node.

Replay synthesis does NOT call any of this math to resolve a
hand-card's viewport position — it uses `Browser.Dom.getElement`
on `handCardDomId` to read the live rect directly. That
eliminates drift between the pinned formula and what actually
renders (origins that used to land wrong because they trusted
stale pinned math).

-}

import LynRummy.BoardGeometry as BG
import LynRummy.Card exposing (Card, OriginDeck(..))


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


{-| Viewport (x, y) of the center of a card at grid position
`{ row, col }`. Used by `View` when rendering; replay synthesis
uses DOM measurement instead.
-}
positionAt : { row : Int, col : Int } -> { x : Int, y : Int }
positionAt { row, col } =
    { x = handLeft + col * BG.cardPitch + (BG.cardPitch // 2)
    , y = handTop + row * suitRowHeight + (BG.cardHeight // 2)
    }


{-| Stable DOM id for a hand card. Used by the replay
synthesizer to fetch the card's LIVE viewport rect via
`Browser.Dom.getElement`. Deck is disambiguated in the id so
the double-deck's two copies of (say) 7H each get a distinct
DOM node.
-}
handCardDomId : Card -> String
handCardDomId card =
    "hand-card-v"
        ++ String.fromInt (LynRummy.Card.cardValueToInt card.value)
        ++ "-s"
        ++ String.fromInt (LynRummy.Card.suitToInt card.suit)
        ++ "-d"
        ++ (case card.originDeck of
                DeckOne ->
                    "1"

                DeckTwo ->
                    "2"
           )
