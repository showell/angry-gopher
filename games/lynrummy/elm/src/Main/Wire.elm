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
import Game.Game exposing (GameState)
import Game.InitialStateDsl as InitialStateDsl
import Game.WireAction as WA
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Main.Msg exposing (Msg(..))



-- OUTBOUND CALLS


{-| Create a new session. Elm has already dealt the game
locally; this just registers it. `initialState` is the
DSL-encoded GameState (a multi-line string). The server is
dumb storage and persists it verbatim in `meta.initial_state`.
-}
fetchNewSession : String -> Cmd Msg
fetchNewSession initialState =
    Http.post
        { url = "/gopher/lynrummy-elm/new-session"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "label", Encode.string "" )
                    , ( "initial_state", Encode.string initialState )
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


initialStateDecoder : Decoder GameState
initialStateDecoder =
    Decode.string
        |> Decode.andThen
            (\dsl ->
                case InitialStateDsl.parseGameState dsl of
                    Ok gs ->
                        Decode.succeed gs

                    Err msg ->
                        Decode.fail ("initial_state DSL: " ++ msg)
            )


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
