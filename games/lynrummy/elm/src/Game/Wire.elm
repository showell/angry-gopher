module Game.Wire exposing
    ( fetchActionLog
    , fetchNewSession
    , sendAction
    )

{-| HTTP surface between the Elm client and the Gopher server.
The server is a dumb URL-keyed file store; this module is a
thin afterthought layer.

Everything on the wire is DSL text — no JSON envelopes (apart
from the new-session response, which still carries one int).
Resume payload is one text/plain document: the meta DSL, then
a `---` separator line, then the action-log DSL lines. Elm
splits and parses each half.

-}

import Lib.ActionLog exposing (ActionLogEntry)
import Lib.Game exposing (GameState)
import Lib.InitialStateDsl as InitialStateDsl
import Lib.WireAction as WA
import Http
import Json.Decode as Decode exposing (Decoder)
import Game.Msg exposing (Msg(..))



-- OUTBOUND CALLS


{-| Create a new session. Elm has already dealt the game
locally; this just registers it. `initialState` is the
DSL-encoded GameState. Server prepends its own metadata
scalars and persists the result verbatim in `meta`.
-}
fetchNewSession : String -> Cmd Msg
fetchNewSession initialState =
    Http.post
        { url = "/gopher/lynrummy-elm/new-session"
        , body = Http.stringBody "text/plain" initialState
        , expect = Http.expectJson SessionReceived sessionIdDecoder
        }


fetchActionLog : Int -> Cmd Msg
fetchActionLog sid =
    Http.get
        { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/actions"
        , expect = Http.expectStringResponse ActionLogFetched parseResumeBundle
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


{-| Resume bundle is one text/plain document: meta DSL, then a
line containing exactly `---`, then the action-log DSL. Split,
parse each half, surface either as an Http error so the caller
sees a uniform failure shape.
-}
parseResumeBundle :
    Http.Response String
    -> Result Http.Error ( GameState, List ActionLogEntry )
parseResumeBundle response =
    case response of
        Http.GoodStatus_ _ body ->
            splitBundle body
                |> Result.andThen
                    (\( metaDsl, actionsDsl ) ->
                        Result.map2 Tuple.pair
                            (InitialStateDsl.parseGameState metaDsl)
                            (parseActionLines actionsDsl)
                    )
                |> Result.mapError (\msg -> Http.BadBody msg)

        Http.BadStatus_ meta _ ->
            Err (Http.BadStatus meta.statusCode)

        Http.NetworkError_ ->
            Err Http.NetworkError

        Http.Timeout_ ->
            Err Http.Timeout

        Http.BadUrl_ url ->
            Err (Http.BadUrl url)


splitBundle : String -> Result String ( String, String )
splitBundle src =
    case String.split "\n---\n" src of
        [ meta, actions ] ->
            Ok ( meta, actions )

        [ _ ] ->
            -- No actions yet (fresh session). The separator is
            -- still required even if the second half is empty;
            -- treat its absence as a server bug rather than
            -- silently inferring.
            Err "resume bundle missing '---' separator"

        _ ->
            Err "resume bundle has multiple '---' separators"


parseActionLines : String -> Result String (List ActionLogEntry)
parseActionLines src =
    src
        |> String.lines
        |> List.map String.trim
        |> List.filter (\l -> l /= "")
        |> sequenceParse
        |> Result.map (List.map (\p -> { action = p.event }))


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
