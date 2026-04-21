module LynRummy.WireAction exposing
    ( WireAction(..)
    , decoder
    , encode
    )

{-| Action-shaped wire format for the LynRummy port. Each
value of `WireAction` names a thing the player did, rather
than the mechanical diff that resulted. Receiver derives the
post-state by applying the action to the known prior state.

See `showell/claude_writings/actions_not_diffs.md` for the
rationale and the Go-side counterpart plan.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import LynRummy.BoardActions exposing (Side(..))
import LynRummy.Card as Card exposing (Card)
import LynRummy.CardStack exposing (BoardLocation, CardStack, boardLocationDecoder, cardStackDecoder, encodeBoardLocation, encodeCardStack)


type WireAction
    = Split { stackIndex : Int, cardIndex : Int }
    | MergeStack { sourceStack : Int, targetStack : Int, side : Side }
    | MergeHand { handCard : Card, targetStack : Int, side : Side }
    | PlaceHand { handCard : Card, loc : BoardLocation }
    | MoveStack { stackIndex : Int, newLoc : BoardLocation }
    | CompleteTurn
    | Undo



-- ENCODE


encode : WireAction -> Value
encode action =
    case action of
        Split p ->
            Encode.object
                [ ( "action", Encode.string "split" )
                , ( "stack_index", Encode.int p.stackIndex )
                , ( "card_index", Encode.int p.cardIndex )
                ]

        MergeStack p ->
            Encode.object
                [ ( "action", Encode.string "merge_stack" )
                , ( "source_stack", Encode.int p.sourceStack )
                , ( "target_stack", Encode.int p.targetStack )
                , ( "side", encodeSide p.side )
                ]

        MergeHand p ->
            Encode.object
                [ ( "action", Encode.string "merge_hand" )
                , ( "hand_card", Card.encodeCard p.handCard )
                , ( "target_stack", Encode.int p.targetStack )
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
                , ( "stack_index", Encode.int p.stackIndex )
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
                (\stackIndex cardIndex ->
                    Split { stackIndex = stackIndex, cardIndex = cardIndex }
                )
                (Decode.field "stack_index" Decode.int)
                (Decode.field "card_index" Decode.int)

        "merge_stack" ->
            Decode.map3
                (\sourceStack targetStack side ->
                    MergeStack
                        { sourceStack = sourceStack
                        , targetStack = targetStack
                        , side = side
                        }
                )
                (Decode.field "source_stack" Decode.int)
                (Decode.field "target_stack" Decode.int)
                (Decode.field "side" sideDecoder)

        "merge_hand" ->
            Decode.map3
                (\handCard targetStack side ->
                    MergeHand
                        { handCard = handCard
                        , targetStack = targetStack
                        , side = side
                        }
                )
                (Decode.field "hand_card" Card.cardDecoder)
                (Decode.field "target_stack" Decode.int)
                (Decode.field "side" sideDecoder)

        "place_hand" ->
            Decode.map2
                (\handCard loc -> PlaceHand { handCard = handCard, loc = loc })
                (Decode.field "hand_card" Card.cardDecoder)
                (Decode.field "loc" boardLocationDecoder)

        "move_stack" ->
            Decode.map2
                (\stackIndex newLoc ->
                    MoveStack { stackIndex = stackIndex, newLoc = newLoc }
                )
                (Decode.field "stack_index" Decode.int)
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
