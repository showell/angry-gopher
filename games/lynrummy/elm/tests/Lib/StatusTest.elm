module Lib.StatusTest exposing (suite)

import Expect
import Lib.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Lib.Status as Status exposing (TextSegment(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Status.cardSegments"
        [ test "hint line splits into plain runs and card tokens" <|
            \_ ->
                Status.cardSegments "peel 9♥ from 9♥ T♠ onto T♥"
                    |> Expect.equal
                        [ Plain "peel "
                        , CardText { value = Nine, suit = Heart, originDeck = DeckOne }
                        , Plain " from "
                        , CardText { value = Nine, suit = Heart, originDeck = DeckOne }
                        , Plain " "
                        , CardText { value = Ten, suit = Spade, originDeck = DeckOne }
                        , Plain " onto "
                        , CardText { value = Ten, suit = Heart, originDeck = DeckOne }
                        ]
        , test "text without suit glyphs is one plain run" <|
            \_ ->
                Status.cardSegments "No hint — no obvious play for this hand on this board."
                    |> Expect.equal
                        [ Plain "No hint — no obvious play for this hand on this board." ]
        , test "a glyph without a rank char before it stays plain" <|
            \_ ->
                Status.cardSegments "we ♥ cards"
                    |> Expect.equal [ Plain "we ♥ cards" ]
        , test "letter suits are NOT card tokens (only glyphs trigger)" <|
            \_ ->
                Status.cardSegments "AS IS"
                    |> Expect.equal [ Plain "AS IS" ]
        , test "cardDisplay renders tens as 10, as on the card faces" <|
            \_ ->
                Status.cardDisplay { value = Ten, suit = Spade, originDeck = DeckOne }
                    |> Expect.equal "10♠"
        , test "cardDisplay keeps letter ranks as-is" <|
            \_ ->
                Status.cardDisplay { value = Ace, suit = Diamond, originDeck = DeckOne }
                    |> Expect.equal "A♦"
        ]
