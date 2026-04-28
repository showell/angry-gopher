module Game.WireAction exposing
    ( WireAction(..)
    , decoder
    , encode
    )

{-| Action-shaped wire format for the Lyn Rummy port. Each
value of `WireAction` names a thing the player did, rather
than the mechanical diff that resulted. Receiver derives the
post-state by applying the action to the known prior state.

Stacks are referenced by their **full ordered card list**
(`cards`, `source_cards`, `target_cards`), not by positional
index. Cards are globally unique in the double deck, so a card
list identifies a stack unambiguously AND stays stable under
the reducer's reordering. See `games/lynrummy/WIRE.md`.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Game.BoardActions exposing (Side(..))
import Game.Rules.Card as Card exposing (Card)
import Game.CardStack exposing (BoardLocation, CardStack, boardLocationDecoder, cardStackDecoder, encodeBoardLocation, encodeCardStack)


type WireAction
    = Split { stack : CardStack, cardIndex : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side }
    | MergeHand { handCard : Card, target : CardStack, side : Side }
    | PlaceHand { handCard : Card, loc : BoardLocation }
    | MoveStack { stack : CardStack, newLoc : BoardLocation }
    | CompleteTurn
    | Undo



-- ENCODE


encode : WireAction -> Value
encode action =
    case action of
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


decoder : Decoder WireAction
decoder =
    Decode.field "action" Decode.string
        |> Decode.andThen decoderForAction


decoderForAction : String -> Decoder WireAction
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
