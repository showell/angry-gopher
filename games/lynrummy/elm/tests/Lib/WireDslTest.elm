module Lib.WireDslTest exposing (suite)

{-| Round-trip + literal-shape tests for the wire DSL grammar.
Verifies each per-event encoder in `Lib.GameEvent` produces a
line that `Lib.WireAction.parseDsl` decodes back to the same
event (plus seq).

-}

import Expect
import Lib.BoardActions exposing (Side(..))
import Lib.CardStack exposing (BoardCardState(..), CardStack)
import Lib.GameEvent as GameEvent exposing (GameEvent(..))
import Lib.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Lib.WireAction as WA
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Wire DSL"
        [ literalShapes
        , roundTrips
        ]



-- LITERAL SHAPES (encoder output exactly matches expected string)


literalShapes : Test
literalShapes =
    describe "encoder literal output"
        [ test "split" <|
            \_ ->
                GameEvent.splitDsl 42 sampleStackAceTwoThree 1
                    |> Expect.equal "42) split [A♥ 2♥ 3♥'] at (10,53) @1"
        , test "merge_stack with path" <|
            \_ ->
                GameEvent.mergeStackDsl 43 sampleStackFour sampleStackAceTwoThree Right samplePath
                    |> Expect.equal
                        "43) merge_stack [4♣'] at (200,100) -> [A♥ 2♥ 3♥'] at (10,53) /right :: path (10,53@0)(22,300@500)"
        , test "merge_hand" <|
            \_ ->
                GameEvent.mergeHandDsl 44 sampleSeven sampleStackAceTwoThree Left
                    |> Expect.equal "44) merge_hand 7♥' -> [A♥ 2♥ 3♥'] at (10,53) /left"
        , test "place_hand" <|
            \_ ->
                GameEvent.placeHandDsl 45 sampleSeven { left = 400, top = 300 }
                    |> Expect.equal "45) place_hand 7♥' -> (400,300)"
        , test "move_stack with path" <|
            \_ ->
                GameEvent.moveStackDsl 46 sampleStackAceTwoThree { left = 22, top = 300 } samplePath
                    |> Expect.equal
                        "46) move_stack [A♥ 2♥ 3♥'] at (10,53) -> (22,300) :: path (10,53@0)(22,300@500)"
        , test "complete_turn" <|
            \_ ->
                GameEvent.completeTurnDsl 47
                    |> Expect.equal "47) complete_turn"
        , test "undo" <|
            \_ ->
                GameEvent.undoDsl 48
                    |> Expect.equal "48) undo"
        ]



-- ROUND-TRIPS (encode → parse → equal)


roundTrips : Test
roundTrips =
    describe "encoder → parser round-trip"
        [ test "split" <|
            \_ ->
                let
                    encoded =
                        GameEvent.splitDsl 1 sampleStackAceTwoThree 1
                in
                WA.parseDsl encoded
                    |> Expect.equal
                        (Ok
                            { seq = 1
                            , event =
                                Split { stack = sampleStackAceTwoThree, cardIndex = 1 }
                            }
                        )
        , test "merge_stack" <|
            \_ ->
                let
                    encoded =
                        GameEvent.mergeStackDsl 2 sampleStackFour sampleStackAceTwoThree Right samplePath
                in
                WA.parseDsl encoded
                    |> Expect.equal
                        (Ok
                            { seq = 2
                            , event =
                                MergeStack
                                    { source = sampleStackFour
                                    , target = sampleStackAceTwoThree
                                    , side = Right
                                    , boardPath = samplePath
                                    }
                            }
                        )
        , test "merge_hand" <|
            \_ ->
                let
                    encoded =
                        GameEvent.mergeHandDsl 3 sampleSeven sampleStackAceTwoThree Left
                in
                WA.parseDsl encoded
                    |> Expect.equal
                        (Ok
                            { seq = 3
                            , event =
                                MergeHand
                                    { handCard = sampleSeven
                                    , target = sampleStackAceTwoThree
                                    , side = Left
                                    }
                            }
                        )
        , test "place_hand" <|
            \_ ->
                let
                    encoded =
                        GameEvent.placeHandDsl 4 sampleSeven { left = 400, top = 300 }
                in
                WA.parseDsl encoded
                    |> Expect.equal
                        (Ok
                            { seq = 4
                            , event = PlaceHand { handCard = sampleSeven, loc = { left = 400, top = 300 } }
                            }
                        )
        , test "move_stack" <|
            \_ ->
                let
                    encoded =
                        GameEvent.moveStackDsl 5 sampleStackAceTwoThree { left = 22, top = 300 } samplePath
                in
                WA.parseDsl encoded
                    |> Expect.equal
                        (Ok
                            { seq = 5
                            , event =
                                MoveStack
                                    { stack = sampleStackAceTwoThree
                                    , newLoc = { left = 22, top = 300 }
                                    , boardPath = samplePath
                                    }
                            }
                        )
        , test "complete_turn" <|
            \_ ->
                WA.parseDsl (GameEvent.completeTurnDsl 6)
                    |> Expect.equal (Ok { seq = 6, event = CompleteTurn })
        , test "undo" <|
            \_ ->
                WA.parseDsl (GameEvent.undoDsl 7)
                    |> Expect.equal (Ok { seq = 7, event = Undo })
        , test "parser accepts ASCII suit chars too" <|
            \_ ->
                WA.parseDsl "8) split [AH 2H 3H'] at (10,53) @1"
                    |> Expect.equal
                        (Ok
                            { seq = 8
                            , event =
                                Split { stack = sampleStackAceTwoThree, cardIndex = 1 }
                            }
                        )
        ]



-- SAMPLE VALUES


sampleStackAceTwoThree : CardStack
sampleStackAceTwoThree =
    { boardCards =
        [ { card = { value = Ace, suit = Heart, originDeck = DeckOne }, state = FirmlyOnBoard }
        , { card = { value = Two, suit = Heart, originDeck = DeckOne }, state = FirmlyOnBoard }
        , { card = { value = Three, suit = Heart, originDeck = DeckTwo }, state = FirmlyOnBoard }
        ]
    , loc = { left = 10, top = 53 }
    }


sampleStackFour : CardStack
sampleStackFour =
    { boardCards =
        [ { card = { value = Four, suit = Club, originDeck = DeckTwo }, state = FirmlyOnBoard }
        ]
    , loc = { left = 200, top = 100 }
    }


sampleSeven : Card
sampleSeven =
    { value = Seven, suit = Heart, originDeck = DeckTwo }


samplePath : List { tMs : Int, left : Int, top : Int }
samplePath =
    [ { tMs = 0, left = 10, top = 53 }
    , { tMs = 500, left = 22, top = 300 }
    ]
