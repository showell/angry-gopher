module Main.Wire exposing
    ( encodeGesturePoint
    , fetchActionLog
    , fetchNewSession
    , pathFrameString
    , sendAction
    )

{-| HTTP surface between the Elm client and the Gopher server.
The server is a dumb URL-keyed file store as of LEAN_PASS phase 2
(2026-04-28); this module is a thin afterthought layer, not a
load-bearing concept in the Elm app's architecture.

Three outbound calls (`fetchNewSession`, `fetchActionLog`,
`sendAction`) plus the inbound decoders for the bootstrap
bundle. `sendAction` is now a thin wrapper: take a `Maybe Int`
session id and a fully-formed JSON body, POST if there's a
session, no-op otherwise. The body is built at the dispatch
site (in `Main.Play.handleMouseUp`) with exactly the fields
the action carries — no `Maybe Envelope` parameter, no shared
envelope-wrapper. `encodeGesturePoint` and `pathFrameString`
are exposed as primitive helpers for callers that splice
gesture metadata into their bodies.

-}

import Game.Rules.Card as Card
import Game.CardStack as CardStack
import Game.Hand exposing (Hand)
import Game.WireAction as WA
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Main.Msg exposing (Msg(..))
import Game.Game exposing (GameState)
import Main.State exposing (ActionLogBundle, ActionLogEntry)
import Main.Types exposing (GesturePoint, PathFrame(..))



-- OUTBOUND CALLS


{-| Create a new session. Elm has already dealt the game
locally; this just registers it. Body: `{label, initial_state}`.
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


{-| Bootstrap a session for resume: fetch the meta + action log.
Elm decodes initial_state from `meta.initial_state` and replays
the actions locally.
-}
fetchActionLog : Int -> Cmd Msg
fetchActionLog sid =
    Http.get
        { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/actions"
        , expect = Http.expectJson ActionLogFetched actionLogDecoder
        }


{-| POST a fully-formed body to the action log endpoint.
No-op when the session id is `Nothing` (offline mode — the
session hasn't been allocated yet). The dispatch site builds
the body inline, knowing exactly what fields its action
carries — there is no shared envelope-wrapper here.
-}
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


pathFrameString : PathFrame -> String
pathFrameString frame =
    case frame of
        BoardFrame ->
            "board"

        ViewportFrame ->
            "viewport"


encodeGesturePoint : GesturePoint -> Value
encodeGesturePoint p =
    Encode.object
        [ ( "t", Encode.float p.tMs )
        , ( "x", Encode.int p.x )
        , ( "y", Encode.int p.y )
        ]



-- INBOUND DECODERS


sessionIdDecoder : Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int


handDecoder : Decoder Hand
handDecoder =
    Decode.field "hand_cards" (Decode.list CardStack.handCardDecoder)
        |> Decode.map (\cards -> { handCards = cards })


{-| The dealt-state record as the server stores it. Same shape
the Puzzles catalog ships per puzzle.
-}
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
    Decode.map3 ActionLogEntry
        (Decode.field "action" WA.decoder)
        (Decode.maybe
            (Decode.at [ "gesture_metadata", "path" ] (Decode.list gesturePointDecoder))
        )
        (Decode.oneOf
            [ Decode.at [ "gesture_metadata", "path_frame" ] pathFrameDecoder
            , Decode.succeed ViewportFrame
            ]
        )


pathFrameDecoder : Decoder PathFrame
pathFrameDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "board" ->
                        Decode.succeed BoardFrame

                    "viewport" ->
                        Decode.succeed ViewportFrame

                    other ->
                        Decode.fail ("Unknown path_frame: " ++ other)
            )


gesturePointDecoder : Decoder GesturePoint
gesturePointDecoder =
    Decode.map3 (\t x y -> { tMs = t, x = x, y = y })
        (Decode.field "t" Decode.float)
        (Decode.field "x" Decode.int)
        (Decode.field "y" Decode.int)
