module Game.WireAction exposing (decoder)

{-| Wire decoder for `Game.GameEvent.GameEvent`. The type
itself lives in `Game.GameEvent`; this module is the inbound
half of the serialization layer (used when the action log is
fetched from the server during resume).

The encoder used to live here too, but since the wire body is
built at the dispatch site in `Main.Play.handleMouseUp` (where
the per-action shape is already in hand), there is no
`encode` function — the JSON-shape of each action is at its
one and only producer.

-}

import Json.Decode as Decode exposing (Decoder)
import Game.BoardActions exposing (Side(..))
import Game.GameEvent exposing (GameEvent(..))
import Game.Rules.Card as Card
import Game.CardStack exposing (boardLocationDecoder, cardStackDecoder)



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
