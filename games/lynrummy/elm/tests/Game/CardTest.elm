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
import Json.Decode as Decode
import Json.Encode as Encode
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
        , cardValueToIntTests
        , suitToIntTests
        , originDeckToIntTests
        , allCardValuesCardinalityTests
        , cardColorExhaustiveTests
        , jsonRoundTripTests
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



-- CLASS-1 LOCKDOWN TESTS (added 2026-04-28, phase 3 of game_rules_lockdown)
--
-- Per `feedback_segregate_by_volatility_class.md`: stable rule
-- layer (Class 1/2) gets exhaustive snapshot-style tests. The
-- enum mappings below all carry wire semantics (TS source pins
-- the integers), so a brittle-on-purpose test that fails loudly
-- when someone reorders a constructor is the goal — that's
-- exactly what we want.
--
-- Style choice: exhaustive enumeration over `allCardValues` /
-- `allSuits` rather than fuzz. The domain is finite and tiny
-- (13 values, 4 suits, 2 decks), so enumerate-and-check is both
-- complete AND deterministic. Existing tests in this file use
-- the same idiom (e.g. parser round-trips); we follow.


cardValueToIntTests : Test
cardValueToIntTests =
    describe "cardValueToInt (per-value, wire-semantic)"
        [ test "Ace -> 1" <| \_ -> Expect.equal 1 (cardValueToInt Ace)
        , test "Two -> 2" <| \_ -> Expect.equal 2 (cardValueToInt Two)
        , test "Three -> 3" <| \_ -> Expect.equal 3 (cardValueToInt Three)
        , test "Four -> 4" <| \_ -> Expect.equal 4 (cardValueToInt Four)
        , test "Five -> 5" <| \_ -> Expect.equal 5 (cardValueToInt Five)
        , test "Six -> 6" <| \_ -> Expect.equal 6 (cardValueToInt Six)
        , test "Seven -> 7" <| \_ -> Expect.equal 7 (cardValueToInt Seven)
        , test "Eight -> 8" <| \_ -> Expect.equal 8 (cardValueToInt Eight)
        , test "Nine -> 9" <| \_ -> Expect.equal 9 (cardValueToInt Nine)
        , test "Ten -> 10" <| \_ -> Expect.equal 10 (cardValueToInt Ten)
        , test "Jack -> 11" <| \_ -> Expect.equal 11 (cardValueToInt Jack)
        , test "Queen -> 12" <| \_ -> Expect.equal 12 (cardValueToInt Queen)
        , test "King -> 13" <| \_ -> Expect.equal 13 (cardValueToInt King)
        , test "all values map into [1..13] with no duplicates" <|
            \_ ->
                let
                    ints =
                        List.map cardValueToInt allCardValues
                in
                Expect.all
                    [ \_ -> Expect.equal 13 (List.length ints)
                    , \_ -> Expect.equal 13 (Set.size (Set.fromList ints))
                    , \_ -> Expect.equal True (List.all (\n -> n >= 1 && n <= 13) ints)
                    ]
                    ()
        ]


suitToIntTests : Test
suitToIntTests =
    describe "suitToInt (per-constructor, wire-semantic)"
        -- The TS source pins these specific integers. Don't
        -- reorder — wire format depends on these values.
        [ test "Club -> 0" <| \_ -> Expect.equal 0 (suitToInt Club)
        , test "Diamond -> 1" <| \_ -> Expect.equal 1 (suitToInt Diamond)
        , test "Spade -> 2" <| \_ -> Expect.equal 2 (suitToInt Spade)
        , test "Heart -> 3" <| \_ -> Expect.equal 3 (suitToInt Heart)
        , test "all four suits map to distinct ints in [0..3]" <|
            \_ ->
                let
                    ints =
                        List.map suitToInt allSuits
                in
                Expect.all
                    [ \_ -> Expect.equal 4 (List.length ints)
                    , \_ -> Expect.equal 4 (Set.size (Set.fromList ints))
                    , \_ -> Expect.equal True (List.all (\n -> n >= 0 && n <= 3) ints)
                    ]
                    ()
        ]


originDeckToIntTests : Test
originDeckToIntTests =
    describe "originDeckToInt (per-constructor, wire-semantic)"
        [ test "DeckOne -> 0" <| \_ -> Expect.equal 0 (originDeckToInt DeckOne)
        , test "DeckTwo -> 1" <| \_ -> Expect.equal 1 (originDeckToInt DeckTwo)
        , test "the two decks are distinct" <|
            \_ ->
                Expect.notEqual
                    (originDeckToInt DeckOne)
                    (originDeckToInt DeckTwo)
        ]


allCardValuesCardinalityTests : Test
allCardValuesCardinalityTests =
    describe "allCardValues cardinality"
        [ test "has exactly 13 members" <|
            \_ -> Expect.equal 13 (List.length allCardValues)
        , test "members are pairwise distinct" <|
            \_ ->
                Expect.equal 13
                    (Set.size (Set.fromList (List.map cardValueToInt allCardValues)))
        ]


cardColorExhaustiveTests : Test
cardColorExhaustiveTests =
    describe "cardColor (exhaustive over all 4 suits)"
        -- Locks the suit -> color mapping for the whole deck
        -- via a synthetic Card per suit. The originDeck is
        -- arbitrary because color is a pure function of suit.
        [ test "all Heart cards are Red" <|
            \_ ->
                Expect.equal Red
                    (cardColor { value = Ace, suit = Heart, originDeck = DeckOne })
        , test "all Diamond cards are Red" <|
            \_ ->
                Expect.equal Red
                    (cardColor { value = Ace, suit = Diamond, originDeck = DeckOne })
        , test "all Club cards are Black" <|
            \_ ->
                Expect.equal Black
                    (cardColor { value = Ace, suit = Club, originDeck = DeckOne })
        , test "all Spade cards are Black" <|
            \_ ->
                Expect.equal Black
                    (cardColor { value = Ace, suit = Spade, originDeck = DeckOne })
        , test "cardColor matches suitColor for every (suit, originDeck) pair" <|
            \_ ->
                let
                    pairs =
                        List.concatMap
                            (\s -> [ ( s, DeckOne ), ( s, DeckTwo ) ])
                            allSuits

                    consistent ( s, d ) =
                        cardColor { value = Ace, suit = s, originDeck = d } == suitColor s
                in
                pairs
                    |> List.all consistent
                    |> Expect.equal True
        ]


jsonRoundTripTests : Test
jsonRoundTripTests =
    describe "encodeCard / cardDecoder JSON round-trip"
        -- For every reachable card (13 values × 4 suits × 2
        -- decks = 104 distinct cards), encoding and decoding
        -- must yield the same record. This locks the wire
        -- format: any drift in the int<->enum mappings on
        -- either side surfaces here.
        [ test "encode then decode is identity for every card in the deck" <|
            \_ ->
                let
                    allCards =
                        List.concatMap
                            (\v ->
                                List.concatMap
                                    (\s ->
                                        [ { value = v, suit = s, originDeck = DeckOne }
                                        , { value = v, suit = s, originDeck = DeckTwo }
                                        ]
                                    )
                                    allSuits
                            )
                            allCardValues

                    roundTrip card =
                        encodeCard card
                            |> Decode.decodeValue cardDecoder
                            |> Result.map (\decoded -> decoded == card)
                            |> Result.withDefault False
                in
                Expect.all
                    [ \_ -> Expect.equal 104 (List.length allCards)
                    , \_ ->
                        allCards
                            |> List.all roundTrip
                            |> Expect.equal True
                    ]
                    ()
        , test "decoder rejects out-of-range value field" <|
            \_ ->
                let
                    bogus =
                        Encode.object
                            [ ( "value", Encode.int 99 )
                            , ( "suit", Encode.int 0 )
                            , ( "origin_deck", Encode.int 0 )
                            ]
                in
                case Decode.decodeValue cardDecoder bogus of
                    Ok _ ->
                        Expect.fail "expected decoder to reject value=99"

                    Err _ ->
                        Expect.pass
        , test "decoder rejects out-of-range suit field" <|
            \_ ->
                let
                    bogus =
                        Encode.object
                            [ ( "value", Encode.int 1 )
                            , ( "suit", Encode.int 9 )
                            , ( "origin_deck", Encode.int 0 )
                            ]
                in
                case Decode.decodeValue cardDecoder bogus of
                    Ok _ ->
                        Expect.fail "expected decoder to reject suit=9"

                    Err _ ->
                        Expect.pass
        , test "decoder rejects out-of-range origin_deck field" <|
            \_ ->
                let
                    bogus =
                        Encode.object
                            [ ( "value", Encode.int 1 )
                            , ( "suit", Encode.int 0 )
                            , ( "origin_deck", Encode.int 5 )
                            ]
                in
                case Decode.decodeValue cardDecoder bogus of
                    Ok _ ->
                        Expect.fail "expected decoder to reject origin_deck=5"

                    Err _ ->
                        Expect.pass
        , test "encoded JSON uses snake_case origin_deck field" <|
            \_ ->
                let
                    encoded =
                        encodeCard { value = Ace, suit = Heart, originDeck = DeckTwo }

                    -- Decoder against the snake_case wire field
                    -- should find the integer 1.
                    deckField =
                        Decode.decodeValue
                            (Decode.field "origin_deck" Decode.int)
                            encoded
                in
                Expect.equal (Ok 1) deckField
        ]
