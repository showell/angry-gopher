module Game.WireTest exposing (suite)

{-| Wire-format round-trip tests. Verifies encoders and
decoders agree (encode → decode → equal) for every type that
crosses a boundary.

Companion test discipline: shape assertions for the JSON
encoders, to lock in wire-format compatibility with TS / Go.
If these tests pass and the TS/Go side asserts the same
literal JSON, the three impls share a common wire format.

-}

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Game.BoardGeometry exposing (BoardBounds, GeometryError, GeometryErrorKind(..), boardBoundsDecoder, encodeBoardBounds, encodeGeometryError, geometryErrorDecoder)
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardDecoder, encodeCard)
import Game.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCard
        , HandCardState(..)
        , boardCardDecoder
        , boardLocationDecoder
        , cardStackDecoder
        , encodeBoardCard
        , encodeBoardLocation
        , encodeCardStack
        , encodeHandCard
        , handCardDecoder
        )
import Game.Referee
    exposing
        ( RefereeError
        , RefereeMove
        , RefereeStage(..)
        , encodeRefereeError
        , encodeRefereeMove
        , encodeRefereeResult
        , refereeErrorDecoder
        , refereeMoveDecoder
        , refereeResultDecoder
        )
import Test exposing (Test, describe, test)



-- HELPERS


roundTrip : (a -> Encode.Value) -> Decode.Decoder a -> a -> Result Decode.Error a
roundTrip encoder decoder value =
    Decode.decodeValue decoder (encoder value)


expectRoundTrip : (a -> Encode.Value) -> Decode.Decoder a -> a -> Expect.Expectation
expectRoundTrip encoder decoder value =
    case roundTrip encoder decoder value of
        Ok decoded ->
            Expect.equal value decoded

        Err err ->
            Expect.fail (Decode.errorToString err)



-- SAMPLE VALUES


sampleCardAH : Card
sampleCardAH =
    { value = Ace, suit = Heart, originDeck = DeckOne }


sampleCardKS : Card
sampleCardKS =
    { value = King, suit = Spade, originDeck = DeckTwo }


sampleLoc : BoardLocation
sampleLoc =
    { top = 10, left = 20 }


sampleBoardCard : BoardCard
sampleBoardCard =
    { card = sampleCardAH, state = FreshlyPlayed }


sampleHandCard : HandCard
sampleHandCard =
    { card = sampleCardKS, state = BackFromBoard }


sampleStack : CardStack
sampleStack =
    { boardCards =
        [ { card = sampleCardAH, state = FirmlyOnBoard }
        , { card = { value = Two, suit = Heart, originDeck = DeckOne }, state = FreshlyPlayed }
        , { card = { value = Three, suit = Heart, originDeck = DeckOne }, state = FreshlyPlayedByLastPlayer }
        ]
    , loc = sampleLoc
    }


sampleBounds : BoardBounds
sampleBounds =
    { maxWidth = 800, maxHeight = 600, margin = 5 }


sampleGeometryError : GeometryError
sampleGeometryError =
    { kind = TooClose
    , message = "Stacks 1 and 2 are too close (within 5px margin)"
    , stackIndices = [ 1, 2 ]
    }


sampleRefereeError : RefereeError
sampleRefereeError =
    { stage = Inventory
    , message = "card AH appeared on the board with no source"
    }


sampleMoveWithHand : RefereeMove
sampleMoveWithHand =
    { boardBefore = [ sampleStack ]
    , stacksToRemove = [ sampleStack ]
    , stacksToAdd = []
    , handCardsPlayed = [ sampleHandCard ]
    }


sampleMoveNoHand : RefereeMove
sampleMoveNoHand =
    { boardBefore = []
    , stacksToRemove = []
    , stacksToAdd = [ sampleStack ]
    , handCardsPlayed = []
    }



-- SUITE


suite : Test
suite =
    describe "Wire-format round-trips"
        [ cardRoundTrips
        , locationAndStackRoundTrips
        , handAndBoardCardRoundTrips
        , geometryRoundTrips
        , refereeRoundTrips
        , shapeAssertions
        ]


cardRoundTrips : Test
cardRoundTrips =
    describe "Card"
        [ test "Ace of Hearts (DeckOne) round-trips" <|
            \_ -> expectRoundTrip encodeCard cardDecoder sampleCardAH
        , test "King of Spades (DeckTwo) round-trips" <|
            \_ -> expectRoundTrip encodeCard cardDecoder sampleCardKS
        , test "every (value, suit, deck) combination round-trips" <|
            \_ ->
                let
                    allCombos =
                        [ Ace, Five, Ten, King ]
                            |> List.concatMap
                                (\v ->
                                    [ Club, Diamond, Spade, Heart ]
                                        |> List.concatMap
                                            (\s ->
                                                [ DeckOne, DeckTwo ]
                                                    |> List.map
                                                        (\d ->
                                                            { value = v, suit = s, originDeck = d }
                                                        )
                                            )
                                )

                    allRoundTrip =
                        allCombos
                            |> List.all
                                (\c ->
                                    roundTrip encodeCard cardDecoder c == Ok c
                                )
                in
                Expect.equal True allRoundTrip
        ]


locationAndStackRoundTrips : Test
locationAndStackRoundTrips =
    describe "BoardLocation and CardStack"
        [ test "BoardLocation round-trips" <|
            \_ -> expectRoundTrip encodeBoardLocation boardLocationDecoder sampleLoc
        , test "CardStack round-trips" <|
            \_ -> expectRoundTrip encodeCardStack cardStackDecoder sampleStack
        , test "empty CardStack round-trips" <|
            \_ ->
                expectRoundTrip encodeCardStack cardStackDecoder
                    { boardCards = [], loc = sampleLoc }
        ]


handAndBoardCardRoundTrips : Test
handAndBoardCardRoundTrips =
    describe "HandCard and BoardCard"
        [ test "BoardCard round-trips" <|
            \_ -> expectRoundTrip encodeBoardCard boardCardDecoder sampleBoardCard
        , test "HandCard round-trips" <|
            \_ -> expectRoundTrip encodeHandCard handCardDecoder sampleHandCard
        , test "every BoardCardState round-trips" <|
            \_ ->
                let
                    allStates =
                        [ FirmlyOnBoard, FreshlyPlayed, FreshlyPlayedByLastPlayer ]

                    allRoundTrip =
                        allStates
                            |> List.all
                                (\s ->
                                    let
                                        bc =
                                            { card = sampleCardAH, state = s }
                                    in
                                    roundTrip encodeBoardCard boardCardDecoder bc
                                        == Ok bc
                                )
                in
                Expect.equal True allRoundTrip
        , test "every HandCardState round-trips" <|
            \_ ->
                let
                    allStates =
                        [ HandNormal, FreshlyDrawn, BackFromBoard ]

                    allRoundTrip =
                        allStates
                            |> List.all
                                (\s ->
                                    let
                                        hc =
                                            { card = sampleCardAH, state = s }
                                    in
                                    roundTrip encodeHandCard handCardDecoder hc
                                        == Ok hc
                                )
                in
                Expect.equal True allRoundTrip
        ]


geometryRoundTrips : Test
geometryRoundTrips =
    describe "BoardBounds and GeometryError"
        [ test "BoardBounds round-trips" <|
            \_ -> expectRoundTrip encodeBoardBounds boardBoundsDecoder sampleBounds
        , test "GeometryError (TooClose / 'crowded') round-trips" <|
            \_ -> expectRoundTrip encodeGeometryError geometryErrorDecoder sampleGeometryError
        , test "every GeometryErrorKind round-trips" <|
            \_ ->
                let
                    allKinds =
                        [ OutOfBounds, Overlap, TooClose ]

                    allRoundTrip =
                        allKinds
                            |> List.all
                                (\k ->
                                    let
                                        ge =
                                            { kind = k, message = "test", stackIndices = [ 0 ] }
                                    in
                                    roundTrip encodeGeometryError geometryErrorDecoder ge
                                        == Ok ge
                                )
                in
                Expect.equal True allRoundTrip
        ]


refereeRoundTrips : Test
refereeRoundTrips =
    describe "RefereeError, RefereeMove, RefereeResult"
        [ test "RefereeError round-trips" <|
            \_ -> expectRoundTrip encodeRefereeError refereeErrorDecoder sampleRefereeError
        , test "every RefereeStage round-trips" <|
            \_ ->
                let
                    allStages =
                        [ Protocol, Geometry, Semantics, Inventory ]

                    allRoundTrip =
                        allStages
                            |> List.all
                                (\stage ->
                                    let
                                        re =
                                            { stage = stage, message = "test" }
                                    in
                                    roundTrip encodeRefereeError refereeErrorDecoder re
                                        == Ok re
                                )
                in
                Expect.equal True allRoundTrip
        , test "RefereeMove with hand cards round-trips" <|
            \_ -> expectRoundTrip encodeRefereeMove refereeMoveDecoder sampleMoveWithHand
        , test "RefereeMove without hand cards round-trips (empty list)" <|
            \_ -> expectRoundTrip encodeRefereeMove refereeMoveDecoder sampleMoveNoHand
        , test "RefereeResult Ok round-trips" <|
            \_ ->
                expectRoundTrip encodeRefereeResult refereeResultDecoder (Ok ())
        , test "RefereeResult Err round-trips" <|
            \_ ->
                expectRoundTrip encodeRefereeResult refereeResultDecoder (Err sampleRefereeError)
        ]



-- SHAPE ASSERTIONS
--
-- Pin specific JSON shapes that the TS / Go sides also produce.
-- If the TS source's snake_case naming changes or an enum
-- value shifts, these tests catch the drift.


shapeAssertions : Test
shapeAssertions =
    describe "JSON shape assertions"
        [ test "Card encodes as { value, suit, origin_deck } with snake_case" <|
            \_ ->
                let
                    json =
                        Encode.encode 0 (encodeCard sampleCardAH)
                in
                -- Ace of Hearts DeckOne = value 1, suit 3, origin_deck 0
                Expect.equal """{"value":1,"suit":3,"origin_deck":0}""" json
        , test "King of Spades DeckTwo encodes correctly" <|
            \_ ->
                let
                    json =
                        Encode.encode 0 (encodeCard sampleCardKS)
                in
                -- value 13, suit 2, origin_deck 1
                Expect.equal """{"value":13,"suit":2,"origin_deck":1}""" json
        , test "BoardLocation encodes as { top, left }" <|
            \_ ->
                Expect.equal """{"top":10,"left":20}"""
                    (Encode.encode 0 (encodeBoardLocation sampleLoc))
        , test "BoardBounds uses snake_case max_width / max_height" <|
            \_ ->
                Expect.equal
                    """{"max_width":800,"max_height":600,"margin":5}"""
                    (Encode.encode 0 (encodeBoardBounds sampleBounds))
        , test "RefereeMove omits hand_cards_played when empty" <|
            \_ ->
                let
                    json =
                        Encode.encode 0 (encodeRefereeMove sampleMoveNoHand)
                in
                Expect.equal False (String.contains "hand_cards_played" json)
        , test "RefereeMove includes hand_cards_played when non-empty" <|
            \_ ->
                let
                    json =
                        Encode.encode 0 (encodeRefereeMove sampleMoveWithHand)
                in
                Expect.equal True (String.contains "hand_cards_played" json)
        , test "RefereeError encodes stage as a string" <|
            \_ ->
                Expect.equal
                    """{"stage":"inventory","message":"card AH appeared on the board with no source"}"""
                    (Encode.encode 0 (encodeRefereeError sampleRefereeError))
        , test "GeometryError encodes 'crowded' (not 'too_close') for TooClose kind" <|
            \_ ->
                let
                    json =
                        Encode.encode 0 (encodeGeometryError sampleGeometryError)
                in
                Expect.equal True (String.contains "\"type\":\"crowded\"" json)
        ]
