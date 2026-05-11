module Game.HandDsl exposing
    ( formatHandBody
    , parseHandBody
    )

{-| DSL encoder + parser for a single hand. The body shape:

    2♥ 5♥ J♥
    A♠ 3♠ K♠
    7♣ 9♣

is the visible card content of `Game.View.viewHand` collapsed
into text — one indented line per non-empty suit (suits in UI
order: Heart, Spade, Diamond, Club; cards sorted ascending by
value). Empty hands emit zero rows.

The header line ("Player One Hand:") is owned by the composer
that wraps multiple hands together, not by this module.

Parsing is row-shape-agnostic: it collects all card tokens
across the body, regardless of how they're split across lines.
Hands are unordered collections internally, so the layout is
purely cosmetic for the encoder; the parser doesn't care.
Cards are decoded as `HandNormal` — initial-state hands carry
no recency markers.

-}

import Game.BoardDsl as BoardDsl
import Game.CardStack exposing (HandCard, HandCardState(..))
import Game.Hand as Hand exposing (Hand)
import Game.Rules.Card as Card



-- FORMAT


{-| Emit the hand body — zero or more indented suit-rows, in
UI order, sorted by value within each row. No trailing newline.
-}
formatHandBody : Hand -> String
formatHandBody hand =
    Hand.sortIntoSuitRows hand
        |> List.map formatRow
        |> String.join "\n"


formatRow : ( Card.Suit, List HandCard ) -> String
formatRow ( _, cards ) =
    "  " ++ String.join " " (List.map (.card >> Card.cardStr) cards)



-- PARSE


{-| Parse the hand body — input is everything after the header
line, with no leading or trailing blank lines. All card tokens
are collected regardless of line breaks; the row layout is
cosmetic, not semantic.
-}
parseHandBody : String -> Result String Hand
parseHandBody src =
    let
        body =
            String.lines src
                |> List.map String.trim
                |> List.filter (\l -> l /= "" && not (String.startsWith "#" l))
                |> String.join " "
    in
    BoardDsl.parseCardTokens body
        |> Result.map
            (\cards ->
                { handCards =
                    List.map (\c -> { card = c, state = HandNormal }) cards
                }
            )
