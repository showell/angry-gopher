module LynRummy.WireActionTest exposing (suite)

{-| Tests for `LynRummy.WireAction` — the new action-shaped
wire format. Round-trip tests prove encode/decode are
inverses; format tests lock the specific JSON shape so
accidental drift during future edits gets caught.
-}

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import LynRummy.BoardActions exposing (Side(..))
import LynRummy.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import LynRummy.WireAction as WA exposing (WireAction(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "WireAction"
        [ describe "round-trip (encode → decode → equal)"
            [ roundTrip "split"
                (Split { stackIndex = 5, cardIndex = 2 })
            , roundTrip "merge_stack left"
                (MergeStack { sourceStack = 5, targetStack = 3, side = Left })
            , roundTrip "merge_stack right"
                (MergeStack { sourceStack = 5, targetStack = 3, side = Right })
            , roundTrip "merge_hand"
                (MergeHand { handCard = card8H, targetStack = 5, side = Right })
            , roundTrip "place_hand"
                (PlaceHand { handCard = card8H, loc = { top = 140, left = 220 } })
            , roundTrip "move_stack"
                (MoveStack { stackIndex = 5, newLoc = { top = 140, left = 220 } })
            , roundTrip "complete_turn" CompleteTurn
            , roundTrip "undo" Undo
            ]
        , describe "JSON shape (locks the wire format)"
            [ test "split — tag + indices, nothing else" <|
                \_ ->
                    WA.encode (Split { stackIndex = 5, cardIndex = 2 })
                        |> Encode.encode 0
                        |> Expect.equal """{"action":"split","stack_index":5,"card_index":2}"""
            , test "merge_stack — side lowercased" <|
                \_ ->
                    WA.encode (MergeStack { sourceStack = 1, targetStack = 2, side = Right })
                        |> Encode.encode 0
                        |> Expect.equal """{"action":"merge_stack","source_stack":1,"target_stack":2,"side":"right"}"""
            , test "complete_turn — bare tag" <|
                \_ ->
                    WA.encode CompleteTurn
                        |> Encode.encode 0
                        |> Expect.equal """{"action":"complete_turn"}"""
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
                        """{"action":"merge_stack","source_stack":1,"target_stack":2,"side":"middle"}"""
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
