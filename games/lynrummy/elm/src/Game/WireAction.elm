module Game.WireAction exposing (entryDecoder)

{-| Wire decoder for action-log entries. The wire shape mirrors
the in-memory `GameEvent` exactly: each action is a single JSON
object that names its kind and carries its full payload — for
`merge_stack` and `move_stack`, that includes `board_path`.

The encoder lives at the dispatch site
(`Game.BoardDrag.handleMouseUp` and friends).

-}

import Game.BoardActions exposing (Side(..))
import Game.CardStack exposing (boardLocationDecoder, cardStackDecoder)
import Game.GameEvent exposing (GameEvent(..))
import Game.Rules.Card as Card
import Game.TimeLoc exposing (TimeLoc)
import Json.Decode as Decode exposing (Decoder)


entryDecoder : Decoder GameEvent
entryDecoder =
    Decode.at [ "action", "action" ] Decode.string
        |> Decode.andThen actionDecoder


actionDecoder : String -> Decoder GameEvent
actionDecoder kind =
    Decode.field "action" (decoderForAction kind)


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
            Decode.map4
                (\source target side path ->
                    MergeStack
                        { source = source
                        , target = target
                        , side = side
                        , boardPath = path
                        }
                )
                (Decode.field "source" cardStackDecoder)
                (Decode.field "target" cardStackDecoder)
                (Decode.field "side" sideDecoder)
                (Decode.field "board_path" (Decode.list timeLocDecoder))

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
            Decode.map3
                (\stack newLoc path ->
                    MoveStack
                        { stack = stack
                        , newLoc = newLoc
                        , boardPath = path
                        }
                )
                (Decode.field "stack" cardStackDecoder)
                (Decode.field "new_loc" boardLocationDecoder)
                (Decode.field "board_path" (Decode.list timeLocDecoder))

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


timeLocDecoder : Decoder TimeLoc
timeLocDecoder =
    Decode.map3 (\t l u -> { tMs = t, left = l, top = u })
        (Decode.field "t_ms" Decode.float)
        (Decode.field "left" Decode.int)
        (Decode.field "top" Decode.int)

