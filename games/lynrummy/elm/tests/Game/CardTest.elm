module Game.CardTest exposing (suite)

{-| Tests for `Game.Rules.Card`. Ported from
`angry-cat/src/lyn_rummy/core/card_test.ts`.

Divergences from the TS source:

  - The `clone` assertion is dropped — Elm values are inherently
    immutable; there's nothing to test.
  - JSON round-trip tests are deferred until the boundary
    plumbing (JSON encoders/decoders) is ported.
  - `build_full_double_deck` tests now ported (ported
    2026-04-14 after `Game.Random` landed). Takes an
    explicit seed in Elm.
  - `cardFromLabel` returns `Maybe Card`; TS throws. Tests are
    adapted accordingly.
  - Added: parser round-trips. Past-Claude's blind spots are
    preserved in the source tests; current-Claude broadens
    coverage where it feels thin.

-}

import Expect
import Game.Rules.Card exposing (..)
import Game.Random as R
import Set
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Game.Rules.Card"
        [ valueStrTests
        , suitEmojiStrTests
        , cardConstructionTests
        , isPairOfDupsTests
        , allSuitsTests
        , parserRoundTripTests
        , buildFullDoubleDeckTests
        ]


valueStrTests : Test
valueStrTests =
    describe "valueStr"
        [ test "Ace -> A" <| \_ -> Expect.equal "A" (valueStr Ace)
        , test "Two -> 2" <| \_ -> Expect.equal "2" (valueStr Two)
        , test "Ten -> T (fixed-width for round-trip)" <|
            \_ -> Expect.equal "T" (valueStr Ten)
        , test "Jack -> J" <| \_ -> Expect.equal "J" (valueStr Jack)
        , test "Queen -> Q" <| \_ -> Expect.equal "Q" (valueStr Queen)
        , test "King -> K" <| \_ -> Expect.equal "K" (valueStr King)
        , test "valueDisplayStr: Ten -> 10 (UI only)" <|
            \_ -> Expect.equal "10" (valueDisplayStr Ten)
        , test "valueDisplayStr: Ace -> A (same as valueStr)" <|
            \_ -> Expect.equal "A" (valueDisplayStr Ace)
        ]


suitEmojiStrTests : Test
suitEmojiStrTests =
    describe "suitEmojiStr"
        [ test "Club" <| \_ -> Expect.equal "\u{2663}" (suitEmojiStr Club)
        , test "Diamond" <| \_ -> Expect.equal "\u{2666}" (suitEmojiStr Diamond)
        , test "Heart" <| \_ -> Expect.equal "\u{2665}" (suitEmojiStr Heart)
        , test "Spade" <| \_ -> Expect.equal "\u{2660}" (suitEmojiStr Spade)
        ]


cardConstructionTests : Test
cardConstructionTests =
    describe "Card construction and derivation"
        [ test "Ace of Hearts: fields read correctly" <|
            \_ ->
                let
                    c =
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                in
                Expect.all
                    [ .value >> Expect.equal Ace
                    , .suit >> Expect.equal Heart
                    , .originDeck >> Expect.equal DeckOne
                    , cardColor >> Expect.equal Red
                    , cardStr >> Expect.equal "A\u{2665}"
                    ]
                    c
        , test "Two of Spades: color derives as Black" <|
            \_ ->
                let
                    c =
                        { value = Two, suit = Spade, originDeck = DeckOne }
                in
                Expect.all
                    [ cardColor >> Expect.equal Black
                    , cardStr >> Expect.equal "2\u{2660}"
                    ]
                    c
        , test "cardFromLabel \"AH\" DeckOne parses Ace of Hearts" <|
            \_ ->
                Expect.equal
                    (Just { value = Ace, suit = Heart, originDeck = DeckOne })
                    (cardFromLabel "AH" DeckOne)
        , test "cardFromLabel \"TC\" DeckTwo parses Ten of Clubs" <|
            \_ ->
                Expect.equal
                    (Just { value = Ten, suit = Club, originDeck = DeckTwo })
                    (cardFromLabel "TC" DeckTwo)
        , test "cardFromLabel malformed returns Nothing" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal Nothing (cardFromLabel "" DeckOne)
                    , \_ -> Expect.equal Nothing (cardFromLabel "A" DeckOne)
                    , \_ -> Expect.equal Nothing (cardFromLabel "AHX" DeckOne)
                    , \_ -> Expect.equal Nothing (cardFromLabel "XH" DeckOne)
                    , \_ -> Expect.equal Nothing (cardFromLabel "AX" DeckOne)
                    , \_ -> Expect.equal Nothing (cardFromLabel "10H" DeckOne)
                    ]
                    ()
        , test "Card record equality: same fields -> equal" <|
            \_ ->
                let
                    a =
                        { value = Ace, suit = Heart, originDeck = DeckOne }

                    b =
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                in
                Expect.equal a b
        , test "Card record equality: different originDeck -> NOT equal" <|
            \_ ->
                let
                    a =
                        { value = Ace, suit = Heart, originDeck = DeckOne }

                    b =
                        { value = Ace, suit = Heart, originDeck = DeckTwo }
                in
                Expect.notEqual a b
        , test "Card record equality: different suit -> NOT equal" <|
            \_ ->
                let
                    a =
                        { value = Ace, suit = Heart, originDeck = DeckOne }

                    b =
                        { value = Two, suit = Spade, originDeck = DeckOne }
                in
                Expect.notEqual a b
        ]


isPairOfDupsTests : Test
isPairOfDupsTests =
    describe "isPairOfDups (ignores originDeck)"
        [ test "same value+suit, different deck -> True" <|
            \_ ->
                Expect.equal True
                    (isPairOfDups
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                        { value = Ace, suit = Heart, originDeck = DeckTwo }
                    )
        , test "same value+suit, same deck -> True (still a dup)" <|
            \_ ->
                Expect.equal True
                    (isPairOfDups
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                    )
        , test "different suit -> False" <|
            \_ ->
                Expect.equal False
                    (isPairOfDups
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                        { value = Ace, suit = Spade, originDeck = DeckOne }
                    )
        , test "different value -> False" <|
            \_ ->
                Expect.equal False
                    (isPairOfDups
                        { value = Ace, suit = Heart, originDeck = DeckOne }
                        { value = Two, suit = Heart, originDeck = DeckOne }
                    )
        ]


allSuitsTests : Test
allSuitsTests =
    describe "allSuits"
        [ test "has four suits" <|
            \_ -> Expect.equal 4 (List.length allSuits)
        , test "contains Heart" <|
            \_ -> Expect.equal True (List.member Heart allSuits)
        , test "contains Spade" <|
            \_ -> Expect.equal True (List.member Spade allSuits)
        , test "contains Diamond" <|
            \_ -> Expect.equal True (List.member Diamond allSuits)
        , test "contains Club" <|
            \_ -> Expect.equal True (List.member Club allSuits)
        ]


buildFullDoubleDeckTests : Test
buildFullDoubleDeckTests =
    describe "buildFullDoubleDeck (seeded)"
        [ test "produces exactly 104 cards" <|
            \_ ->
                let
                    ( deck, _ ) =
                        buildFullDoubleDeck (R.initSeed 42)
                in
                Expect.equal 104 (List.length deck)
        , test "all 104 cards are distinct by value+suit+deck" <|
            \_ ->
                let
                    ( deck, _ ) =
                        buildFullDoubleDeck (R.initSeed 42)

                    keyOf c =
                        cardValueToInt c.value
                            * 100
                            + suitCode c.suit
                            * 10
                            + originCode c.originDeck
                in
                deck
                    |> List.map keyOf
                    |> Set.fromList
                    |> Set.size
                    |> Expect.equal 104
        , test "deck is shuffled (not in sorted value order)" <|
            \_ ->
                let
                    ( deck, _ ) =
                        buildFullDoubleDeck (R.initSeed 42)

                    vals =
                        List.map (.value >> cardValueToInt) deck

                    isSorted xs =
                        List.map2 (<=) xs (List.drop 1 xs)
                            |> List.all identity
                in
                Expect.equal False (isSorted vals)
        , test "same seed -> same deck (determinism)" <|
            \_ ->
                let
                    ( deck1, _ ) =
                        buildFullDoubleDeck (R.initSeed 42)

                    ( deck2, _ ) =
                        buildFullDoubleDeck (R.initSeed 42)
                in
                Expect.equal deck1 deck2
        , test "different seeds -> different decks" <|
            \_ ->
                let
                    ( deck1, _ ) =
                        buildFullDoubleDeck (R.initSeed 42)

                    ( deck2, _ ) =
                        buildFullDoubleDeck (R.initSeed 43)
                in
                Expect.notEqual deck1 deck2
        ]


suitCode : Suit -> Int
suitCode s =
    case s of
        Club ->
            0

        Diamond ->
            1

        Spade ->
            2

        Heart ->
            3


originCode : OriginDeck -> Int
originCode d =
    case d of
        DeckOne ->
            0

        DeckTwo ->
            1


parserRoundTripTests : Test
parserRoundTripTests =
    describe "parser round-trips"
        [ test "valueFromLabel (valueStr v) == Just v for every value" <|
            \_ ->
                allCardValues
                    |> List.map (\v -> ( v, valueFromLabel (valueStr v) ))
                    |> List.all (\( v, result ) -> result == Just v)
                    |> Expect.equal True
        , test "suitFromLabel for canonical labels" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal (Just Club) (suitFromLabel "C")
                    , \_ -> Expect.equal (Just Diamond) (suitFromLabel "D")
                    , \_ -> Expect.equal (Just Heart) (suitFromLabel "H")
                    , \_ -> Expect.equal (Just Spade) (suitFromLabel "S")
                    , \_ -> Expect.equal Nothing (suitFromLabel "X")
                    , \_ -> Expect.equal Nothing (suitFromLabel "")
                    ]
                    ()
        , test "cardFromLabel round-trips via cardStr (for each suit)" <|
            \_ ->
                -- Note: cardStr uses valueStr + suitEmojiStr (not suit *letter*),
                -- so this isn't a literal round-trip. Verified separately:
                -- parse "AH" -> Card -> cardStr is "A♥" — display, not parser label.
                let
                    parseAndCheck label expected =
                        Expect.equal (Just expected) (cardFromLabel label DeckOne)
                in
                Expect.all
                    [ \_ -> parseAndCheck "AC" { value = Ace, suit = Club, originDeck = DeckOne }
                    , \_ -> parseAndCheck "TD" { value = Ten, suit = Diamond, originDeck = DeckOne }
                    , \_ -> parseAndCheck "KH" { value = King, suit = Heart, originDeck = DeckOne }
                    , \_ -> parseAndCheck "2S" { value = Two, suit = Spade, originDeck = DeckOne }
                    ]
                    ()
        ]
