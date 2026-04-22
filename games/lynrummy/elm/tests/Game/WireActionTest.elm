module Game.WireActionTest exposing (suite)

{-| Tests for `Game.WireAction` — the action-shaped wire
format. Round-trip tests prove encode/decode are inverses;
format tests lock the specific JSON shape so accidental drift
gets caught.
-}

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Game.BoardActions exposing (Side(..))
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (BoardCard, BoardCardState(..), CardStack)
import Game.WireAction as WA exposing (WireAction(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "WireAction"
        [ describe "round-trip (encode → decode → equal)"
            [ roundTrip "split"
                (Split { stack = stackKA, cardIndex = 2 })
            , roundTrip "merge_stack left"
                (MergeStack { source = stackKA, target = stack7s, side = Left })
            , roundTrip "merge_stack right"
                (MergeStack { source = stackKA, target = stack7s, side = Right })
            , roundTrip "merge_hand"
                (MergeHand { handCard = card8H, target = stack7s, side = Right })
            , roundTrip "place_hand"
                (PlaceHand { handCard = card8H, loc = { top = 140, left = 220 } })
            , roundTrip "move_stack"
                (MoveStack { stack = stackKA, newLoc = { top = 140, left = 220 } })
            , roundTrip "complete_turn" CompleteTurn
            , roundTrip "undo" Undo
            ]
        , describe "JSON shape (locks the wire format)"
            [ test "complete_turn — bare tag" <|
                \_ ->
                    WA.encode CompleteTurn
                        |> Encode.encode 0
                        |> Expect.equal """{"action":"complete_turn"}"""
            , test "split — tag + stack + cleave" <|
                \_ ->
                    let
                        out =
                            WA.encode (Split { stack = stackKA, cardIndex = 1 })
                                |> Encode.encode 0
                    in
                    Expect.all
                        [ \s -> Expect.equal True (String.contains "\"action\":\"split\"" s)
                        , \s -> Expect.equal True (String.contains "\"stack\":{" s)
                        , \s -> Expect.equal True (String.contains "\"board_cards\":" s)
                        , \s -> Expect.equal True (String.contains "\"card_index\":1" s)
                        ]
                        out
            ]
        , describe "decode errors"
            [ test "unknown action tag is rejected" <|
                \_ ->
                    Decode.decodeString WA.decoder """{"action":"flibbertigibbet"}"""
                        |> Expect.err
            , test "missing payload field is rejected" <|
                \_ ->
                    Decode.decodeString WA.decoder """{"action":"split"}"""
                        |> Expect.err
            , test "invalid side value is rejected" <|
                \_ ->
                    Decode.decodeString WA.decoder
                        """{"action":"merge_stack","source":{"board_cards":[],"loc":{"top":0,"left":0}},"target":{"board_cards":[],"loc":{"top":0,"left":0}},"side":"middle"}"""
                        |> Expect.err
            , test "missing action tag is rejected" <|
                \_ ->
                    Decode.decodeString WA.decoder "{}"
                        |> Expect.err
            ]
        ]



-- HELPERS


roundTrip : String -> WireAction -> Test
roundTrip name action =
    test name <|
        \_ ->
            WA.encode action
                |> Encode.encode 0
                |> Decode.decodeString WA.decoder
                |> Expect.equal (Ok action)


card8H : Card
card8H =
    { value = Eight, suit = Heart, originDeck = DeckOne }


bc : CardValue -> Suit -> OriginDeck -> BoardCard
bc v s d =
    { card = { value = v, suit = s, originDeck = d }
    , state = FirmlyOnBoard
    }


stackKA : CardStack
stackKA =
    { boardCards =
        [ bc King Spade DeckOne
        , bc Ace Spade DeckOne
        ]
    , loc = { top = 20, left = 40 }
    }


stack7s : CardStack
stack7s =
    { boardCards =
        [ bc Seven Spade DeckOne
        , bc Seven Diamond DeckOne
        , bc Seven Club DeckOne
        ]
    , loc = { top = 200, left = 130 }
    }
