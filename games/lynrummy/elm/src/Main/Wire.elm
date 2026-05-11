module Main.Wire exposing
    ( fetchActionLog
    , fetchNewSession
    , sendAction
    )

{-| HTTP surface between the Elm client and the Gopher server.
The server is a dumb URL-keyed file store; this module is a
thin afterthought layer.

Actions ride the wire as DSL text lines (one per action). The
resume bootstrap returns `{meta: {...}, actions: [...]}` where
`actions[]` is a list of DSL strings — Elm parses each via
`Game.WireAction.parseDsl`.

-}

import Game.ActionLog exposing (ActionLogEntry)
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


sendAction : Maybe Int -> String -> Cmd Msg
sendAction maybeSessionId line =
    case maybeSessionId of
        Just sid ->
            Http.post
                { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/actions"
                , body = Http.stringBody "text/plain" line
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


actionLogDecoder : Decoder ( GameState, List ActionLogEntry )
actionLogDecoder =
    Decode.map2 Tuple.pair
        (Decode.at [ "meta", "initial_state" ] initialStateDecoder)
        (Decode.field "actions" (Decode.list Decode.string)
            |> Decode.andThen parseDslLines
        )


parseDslLines : List String -> Decoder (List ActionLogEntry)
parseDslLines lines =
    case sequenceParse lines of
        Ok parsed ->
            Decode.succeed (List.map (\p -> { action = p.event }) parsed)

        Err err ->
            Decode.fail ("action log DSL parse: " ++ err)


sequenceParse : List String -> Result String (List WA.ParsedLine)
sequenceParse =
    List.foldr
        (\line acc ->
            Result.andThen
                (\xs ->
                    WA.parseDsl line
                        |> Result.map (\p -> p :: xs)
                )
                acc
        )
        (Ok [])
