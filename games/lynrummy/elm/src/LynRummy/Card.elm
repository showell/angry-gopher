module LynRummy.Card exposing
    ( Card
    , CardColor(..)
    , CardValue(..)
    , OriginDeck(..)
    , Suit(..)
    , allCardValues
    , allSuits
    , buildFullDoubleDeck
    , cardColor
    , cardDecoder
    , cardFromLabel
    , cardStr
    , cardValueToInt
    , encodeCard
    , intToCardValue
    , intToOriginDeck
    , intToSuit
    , isPairOfDups
    , originDeckToInt
    , suitColor
    , suitEmojiStr
    , suitFromLabel
    , suitToInt
    , valueDisplayStr
    , valueFromLabel
    , valueStr
    )

{-| Card domain types and pure helpers. Ported from
`angry-cat/src/lyn_rummy/core/card.ts` (TypeScript, canonical).

The port mirrors the source module 1:1 for easy diff against the
canonical. Intentional Elm divergences:

  - `CardColor` is derived on demand via `cardColor` / `suitColor`,
    not stored as a field on `Card`. Don't carry state that's a
    pure function of other state.
  - Parsers return `Maybe`; TS throws.
  - JSON wire-format mirrors TS exactly: snake\_case field
    names, numeric values for enums (CardValue 1-13, Suit 0-3,
    OriginDeck 0-1). The boundary flips the camelCase
    convention used internally.
  - PRNG (`mulberry32`) lives in `LynRummy.Random` — this module
    just uses it via `buildFullDoubleDeck` which accepts a seed.


# Two equality concepts for `Card`

`Card` has two distinct, deliberate equality concepts. Use the
right one for the right question:

  - **`==`** (record default, full identity) — checks `value`,
    `suit`, AND `originDeck`. Use when you mean "is this the
    same physical card from the same deck?" The referee uses
    `==` (via `List.member`) to detect board duplicates and to
    match cards in the inventory check.
  - **`isPairOfDups`** — checks `value` and `suit`, ignores
    `originDeck`. Use when you mean "are these two cards
    duplicates by game rules?" Two AHs from different decks
    are a dup; same game-rules card type. The classifier
    (`getStackType` in `LynRummy.StackType`) uses this to
    detect dup sets.

Multiple equality concepts is a normal property of domain
types — there's no single "right" answer; the names express the
intent. Use them.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import LynRummy.Random



-- TYPES


type CardValue
    = Ace
    | Two
    | Three
    | Four
    | Five
    | Six
    | Seven
    | Eight
    | Nine
    | Ten
    | Jack
    | Queen
    | King


type Suit
    = Club
    | Diamond
    | Spade
    | Heart


type CardColor
    = Black
    | Red


type OriginDeck
    = DeckOne
    | DeckTwo


type alias Card =
    { value : CardValue
    , suit : Suit
    , originDeck : OriginDeck
    }



-- CARD VALUE ARITHMETIC


cardValueToInt : CardValue -> Int
cardValueToInt v =
    case v of
        Ace ->
            1

        Two ->
            2

        Three ->
            3

        Four ->
            4

        Five ->
            5

        Six ->
            6

        Seven ->
            7

        Eight ->
            8

        Nine ->
            9

        Ten ->
            10

        Jack ->
            11

        Queen ->
            12

        King ->
            13


-- CARD EQUIVALENCE


{-| In a two-deck game, two cards can both be the Ace of Hearts
(one from each deck), but you can't put dups in a set. Equality
for "dup" purposes ignores `originDeck`; record equality on
`Card` (==) includes it.
-}
isPairOfDups : Card -> Card -> Bool
isPairOfDups a b =
    a.value == b.value && a.suit == b.suit



-- COLOR (derived)


cardColor : Card -> CardColor
cardColor card =
    suitColor card.suit


suitColor : Suit -> CardColor
suitColor suit =
    case suit of
        Club ->
            Black

        Spade ->
            Black

        Diamond ->
            Red

        Heart ->
            Red



-- STRINGS


{-| Parser-friendly string for a card value. Tens are always "T"
so labels are fixed-width and round-trip with `cardFromLabel`.
For player-facing UI, use `valueDisplayStr`.
-}
valueStr : CardValue -> String
valueStr v =
    case v of
        Ace ->
            "A"

        Two ->
            "2"

        Three ->
            "3"

        Four ->
            "4"

        Five ->
            "5"

        Six ->
            "6"

        Seven ->
            "7"

        Eight ->
            "8"

        Nine ->
            "9"

        Ten ->
            "T"

        Jack ->
            "J"

        Queen ->
            "Q"

        King ->
            "K"


{-| Player-facing display: tens render as "10". Use this only
for UI; code paths that need to round-trip should use `valueStr`
(which returns "T").
-}
valueDisplayStr : CardValue -> String
valueDisplayStr v =
    case v of
        Ten ->
            "10"

        _ ->
            valueStr v


suitEmojiStr : Suit -> String
suitEmojiStr suit =
    case suit of
        Club ->
            "\u{2663}"

        Diamond ->
            "\u{2666}"

        Heart ->
            "\u{2665}"

        Spade ->
            "\u{2660}"


cardStr : Card -> String
cardStr card =
    valueStr card.value ++ suitEmojiStr card.suit



-- PARSING


valueFromLabel : String -> Maybe CardValue
valueFromLabel label =
    case label of
        "A" ->
            Just Ace

        "2" ->
            Just Two

        "3" ->
            Just Three

        "4" ->
            Just Four

        "5" ->
            Just Five

        "6" ->
            Just Six

        "7" ->
            Just Seven

        "8" ->
            Just Eight

        "9" ->
            Just Nine

        "T" ->
            Just Ten

        "J" ->
            Just Jack

        "Q" ->
            Just Queen

        "K" ->
            Just King

        _ ->
            Nothing


suitFromLabel : String -> Maybe Suit
suitFromLabel label =
    case label of
        "C" ->
            Just Club

        "D" ->
            Just Diamond

        "H" ->
            Just Heart

        "S" ->
            Just Spade

        _ ->
            Nothing


{-| Parse a two-char card label plus an origin deck.
`"AH"` + `DeckOne` -> `Just { value = Ace, suit = Heart, originDeck = DeckOne }`.
Returns `Nothing` for any malformed label.
-}
cardFromLabel : String -> OriginDeck -> Maybe Card
cardFromLabel label deck =
    case String.toList label of
        [ v, s ] ->
            Maybe.map2
                (\value suit ->
                    { value = value, suit = suit, originDeck = deck }
                )
                (valueFromLabel (String.fromChar v))
                (suitFromLabel (String.fromChar s))

        _ ->
            Nothing



-- ENUMERATION


{-| All suits in the TS source's display order: Heart, Spade,
Diamond, Club. Used by deck-building helpers.
-}
allSuits : List Suit
allSuits =
    [ Heart, Spade, Diamond, Club ]


allCardValues : List CardValue
allCardValues =
    [ Ace
    , Two
    , Three
    , Four
    , Five
    , Six
    , Seven
    , Eight
    , Nine
    , Ten
    , Jack
    , Queen
    , King
    ]



-- DECK BUILDING


{-| Build a full shuffled two-deck = 104 cards. Takes a PRNG
seed and returns `(shuffledDeck, finalSeed)` so the caller can
keep using the seed stream for further ops.

Ported from `build_full_double_deck` in `card.ts`. TS version
used an optional `rand` closure defaulting to `Math.random`;
Elm version always requires a seed for determinism (and for
cross-language trace equivalence via the shared mulberry32).

-}
buildFullDoubleDeck : LynRummy.Random.Seed -> ( List Card, LynRummy.Random.Seed )
buildFullDoubleDeck seed =
    let
        suitRun : Suit -> OriginDeck -> List Card
        suitRun suit deck =
            List.map
                (\v -> { value = v, suit = suit, originDeck = deck })
                allCardValues

        allRuns1 =
            List.map (\s -> suitRun s DeckOne) allSuits

        allRuns2 =
            List.map (\s -> suitRun s DeckTwo) allSuits

        allCards =
            List.concat (allRuns1 ++ allRuns2)
    in
    LynRummy.Random.shuffle seed allCards



-- ENUM <-> INT CONVERSIONS
--
-- The TS source uses numeric enums; the wire format carries
-- those integer values. Elm's sum types need explicit
-- conversion functions to interop.


suitToInt : Suit -> Int
suitToInt s =
    case s of
        Club ->
            0

        Diamond ->
            1

        Spade ->
            2

        Heart ->
            3


intToSuit : Int -> Maybe Suit
intToSuit n =
    case n of
        0 ->
            Just Club

        1 ->
            Just Diamond

        2 ->
            Just Spade

        3 ->
            Just Heart

        _ ->
            Nothing


originDeckToInt : OriginDeck -> Int
originDeckToInt d =
    case d of
        DeckOne ->
            0

        DeckTwo ->
            1


intToOriginDeck : Int -> Maybe OriginDeck
intToOriginDeck n =
    case n of
        0 ->
            Just DeckOne

        1 ->
            Just DeckTwo

        _ ->
            Nothing


intToCardValue : Int -> Maybe CardValue
intToCardValue n =
    case n of
        1 ->
            Just Ace

        2 ->
            Just Two

        3 ->
            Just Three

        4 ->
            Just Four

        5 ->
            Just Five

        6 ->
            Just Six

        7 ->
            Just Seven

        8 ->
            Just Eight

        9 ->
            Just Nine

        10 ->
            Just Ten

        11 ->
            Just Jack

        12 ->
            Just Queen

        13 ->
            Just King

        _ ->
            Nothing



-- JSON: WIRE FORMAT
--
-- Mirrors the TS JsonCard shape exactly:
--   { value: <int 1-13>, suit: <int 0-3>, origin_deck: <int 0-1> }
-- snake_case at the boundary; camelCase internally.


encodeCard : Card -> Value
encodeCard card =
    Encode.object
        [ ( "value", Encode.int (cardValueToInt card.value) )
        , ( "suit", Encode.int (suitToInt card.suit) )
        , ( "origin_deck", Encode.int (originDeckToInt card.originDeck) )
        ]


cardDecoder : Decoder Card
cardDecoder =
    Decode.map3
        (\value suit deck -> { value = value, suit = suit, originDeck = deck })
        (Decode.field "value" (intDecoderVia intToCardValue "card value"))
        (Decode.field "suit" (intDecoderVia intToSuit "suit"))
        (Decode.field "origin_deck" (intDecoderVia intToOriginDeck "origin_deck"))


{-| Internal: decode an integer field into an enum value via a
`Int -> Maybe a` partial mapping. Fails the decoder with a
descriptive error if the integer is out of range.
-}
intDecoderVia : (Int -> Maybe a) -> String -> Decoder a
intDecoderVia toMaybe label =
    Decode.int
        |> Decode.andThen
            (\n ->
                case toMaybe n of
                    Just a ->
                        Decode.succeed a

                    Nothing ->
                        Decode.fail
                            ("invalid "
                                ++ label
                                ++ ": "
                                ++ String.fromInt n
                            )
            )
