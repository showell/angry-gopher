module Main.Wire exposing
    ( fetchActionLog
    , fetchNewSession
    , sendAction
    )

{-| HTTP surface between the Elm client and the Gopher server.
The server is a dumb URL-keyed file store; this module is a
thin afterthought layer.

-}

import Game.ActionLog exposing (ActionLogBundle, ActionLogEntry)
import Game.CardStack as CardStack
import Game.Game exposing (GameState)
import Game.Hand exposing (Hand)
import Game.Rules.Card as Card
import Game.WireAction as WA
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Main.Msg exposing (Msg(..))



-- OUTBOUND CALLS


{-| Create a new session. Elm has already dealt the game
locally; this just registers it.
-}
fetchNewSession : Value -> Cmd Msg
fetchNewSession initialState =
    Http.post
        { url = "/gopher/lynrummy-elm/new-session"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "label", Encode.string "" )
                    , ( "initial_state", initialState )
                    ]
                )
        , expect = Http.expectJson SessionReceived sessionIdDecoder
        }


fetchActionLog : Int -> Cmd Msg
fetchActionLog sid =
    Http.get
        { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/actions"
        , expect = Http.expectJson ActionLogFetched actionLogDecoder
        }


sendAction : Maybe Int -> Value -> Cmd Msg
sendAction maybeSessionId body =
    case maybeSessionId of
        Just sid ->
            Http.post
                { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/actions"
                , body = Http.jsonBody body
                , expect = Http.expectWhatever ActionSent
                }

        Nothing ->
            Cmd.none



-- INBOUND DECODERS


sessionIdDecoder : Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int


handDecoder : Decoder Hand
handDecoder =
    Decode.field "hand_cards" (Decode.list CardStack.handCardDecoder)
        |> Decode.map (\cards -> { handCards = cards })


initialStateDecoder : Decoder GameState
initialStateDecoder =
    Decode.map7 GameState
        (Decode.field "board" (Decode.list CardStack.cardStackDecoder))
        (Decode.field "hands" (Decode.list handDecoder))
        (Decode.field "active_player_index" Decode.int)
        (Decode.field "turn_index" Decode.int)
        (Decode.field "deck" (Decode.list Card.cardDecoder))
        (Decode.field "cards_played_this_turn" Decode.int)
        (Decode.field "victor_awarded" Decode.bool)


actionLogDecoder : Decoder ActionLogBundle
actionLogDecoder =
    Decode.map2 ActionLogBundle
        (Decode.at [ "meta", "initial_state" ] initialStateDecoder)
        (Decode.field "actions" (Decode.list actionLogEntryDecoder))


actionLogEntryDecoder : Decoder ActionLogEntry
actionLogEntryDecoder =
    Decode.map (\action -> { action = action }) WA.entryDecoder
