module Game.WireAction exposing
    ( decoder
    , encode
    )

{-| Wire encoder/decoder for `Game.GameEvent.GameEvent`. The
type itself lives in `Game.GameEvent`; this module is the
serialization layer that ships events over the HTTP boundary
to the server's append-only action log.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Game.BoardActions exposing (Side(..))
import Game.GameEvent exposing (GameEvent(..))
import Game.Rules.Card as Card
import Game.CardStack exposing (boardLocationDecoder, cardStackDecoder, encodeBoardLocation, encodeCardStack)



-- ENCODE


encode : GameEvent -> Value
encode event =
    case event of
        Split p ->
            Encode.object
                [ ( "action", Encode.string "split" )
                , ( "stack", encodeCardStack p.stack )
                , ( "card_index", Encode.int p.cardIndex )
                ]

        MergeStack p ->
            Encode.object
                [ ( "action", Encode.string "merge_stack" )
                , ( "source", encodeCardStack p.source )
                , ( "target", encodeCardStack p.target )
                , ( "side", encodeSide p.side )
                ]

        MergeHand p ->
            Encode.object
                [ ( "action", Encode.string "merge_hand" )
                , ( "hand_card", Card.encodeCard p.handCard )
                , ( "target", encodeCardStack p.target )
                , ( "side", encodeSide p.side )
                ]

        PlaceHand p ->
            Encode.object
                [ ( "action", Encode.string "place_hand" )
                , ( "hand_card", Card.encodeCard p.handCard )
                , ( "loc", encodeBoardLocation p.loc )
                ]

        MoveStack p ->
            Encode.object
                [ ( "action", Encode.string "move_stack" )
                , ( "stack", encodeCardStack p.stack )
                , ( "new_loc", encodeBoardLocation p.newLoc )
                ]

        CompleteTurn ->
            Encode.object [ ( "action", Encode.string "complete_turn" ) ]

        Undo ->
            Encode.object [ ( "action", Encode.string "undo" ) ]


encodeSide : Side -> Value
encodeSide side =
    case side of
        Left ->
            Encode.string "left"

        Right ->
            Encode.string "right"



-- DECODE


decoder : Decoder GameEvent
decoder =
    Decode.field "action" Decode.string
        |> Decode.andThen decoderForAction


decoderForAction : String -> Decoder GameEvent
decoderForAction kind =
    case kind of
        "split" ->
            Decode.map2
                (\stack cardIndex ->
                    Split { stack = stack, cardIndex = cardIndex }
                )
                (Decode.field "stack" cardStackDecoder)
                (Decode.field "card_index" Decode.int)

        "merge_stack" ->
            Decode.map3
                (\source target side ->
                    MergeStack { source = source, target = target, side = side }
                )
                (Decode.field "source" cardStackDecoder)
                (Decode.field "target" cardStackDecoder)
                (Decode.field "side" sideDecoder)

        "merge_hand" ->
            Decode.map3
                (\handCard target side ->
                    MergeHand { handCard = handCard, target = target, side = side }
                )
                (Decode.field "hand_card" Card.cardDecoder)
                (Decode.field "target" cardStackDecoder)
                (Decode.field "side" sideDecoder)

        "place_hand" ->
            Decode.map2
                (\handCard loc -> PlaceHand { handCard = handCard, loc = loc })
                (Decode.field "hand_card" Card.cardDecoder)
                (Decode.field "loc" boardLocationDecoder)

        "move_stack" ->
            Decode.map2
                (\stack newLoc ->
                    MoveStack { stack = stack, newLoc = newLoc }
                )
                (Decode.field "stack" cardStackDecoder)
                (Decode.field "new_loc" boardLocationDecoder)

        "complete_turn" ->
            Decode.succeed CompleteTurn

        "undo" ->
            Decode.succeed Undo

        other ->
            Decode.fail ("Unknown action: " ++ other)


sideDecoder : Decoder Side
sideDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "left" ->
                        Decode.succeed Left

                    "right" ->
                        Decode.succeed Right

                    other ->
                        Decode.fail ("Unknown side: " ++ other)
            )
