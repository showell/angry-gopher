module Main.Wire exposing
    ( fetchActionLog
    , fetchNewSession
    , initialStateDecoder
    , sendAction
    )

{-| HTTP surface between the Elm client and the Gopher server.
The server is a dumb URL-keyed file store as of LEAN_PASS phase 2
(2026-04-28); this module is a thin afterthought layer, not a
load-bearing concept in the Elm app's architecture.

Three outbound calls (fetchNewSession, fetchActionLog,
sendAction) plus the inbound decoders for the bootstrap bundle.
sendAction handles every action including CompleteTurn and
puzzle moves — the server doesn't validate, doesn't reply with
turn outcomes, just files the body at
`/sessions/<id>/actions/<seq>`.

-}

import Game.Rules.Card as Card
import Game.CardStack as CardStack
import Game.Hand exposing (Hand)
import Game.WireAction as WA exposing (WireAction)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Main.Msg exposing (Msg(..))
import Main.State exposing (ActionLogBundle, ActionLogEntry, EnvelopeForGesture, GesturePoint, PathFrame(..), RemoteState)



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


{-| Persist one wire action to its own URL-keyed file. Server
just writes the body; no validation, no outcome reply.

Two URL shapes, depending on the session kind:

  - Full game (`maybePuzzleName == Nothing`) →
    `POST /gopher/lynrummy-elm/sessions/<sid>/actions/<seq>`.
    Elm-assigned seq.
  - Puzzle (`maybePuzzleName == Just name`) →
    `POST /gopher/puzzles/sessions/<sid>/<name>/action`.
    Server picks the next per-puzzle seq; the URL carries
    session and puzzle, the body carries only the action
    payload.

The `puzzle_name` is no longer part of the body — the URL is
the namespacing surface.

-}
sendAction :
    Int
    -> Int
    -> Maybe String
    -> WireAction
    -> Maybe EnvelopeForGesture
    -> Cmd Msg
sendAction sessionId seq maybePuzzleName action maybeGesture =
    let
        url =
            case maybePuzzleName of
                Just puzzleName ->
                    "/gopher/puzzles/sessions/"
                        ++ String.fromInt sessionId
                        ++ "/"
                        ++ puzzleName
                        ++ "/action"

                Nothing ->
                    "/gopher/lynrummy-elm/sessions/"
                        ++ String.fromInt sessionId
                        ++ "/actions/"
                        ++ String.fromInt seq
    in
    Http.post
        { url = url
        , body = Http.jsonBody (encodeEnvelope action maybeGesture)
        , expect = Http.expectWhatever ActionSent
        }


pathFrameString : PathFrame -> String
pathFrameString frame =
    case frame of
        BoardFrame ->
            "board"

        ViewportFrame ->
            "viewport"



-- ENVELOPE


{-| Outbound POST body: `{action, gesture_metadata?}`. The
server stores it verbatim; nothing here is parsed server-side
beyond writing the file. Puzzle attribution is URL-borne now,
not body-borne (see `sendAction`).
-}
encodeEnvelope : WireAction -> Maybe EnvelopeForGesture -> Value
encodeEnvelope action maybeGesture =
    let
        baseFields =
            [ ( "action", WA.encode action ) ]

        withGesture =
            case maybeGesture of
                Nothing ->
                    baseFields

                Just { path, frame } ->
                    case path of
                        [] ->
                            baseFields

                        _ ->
                            baseFields
                                ++ [ ( "gesture_metadata"
                                     , Encode.object
                                        [ ( "path", Encode.list encodeGesturePoint path )
                                        , ( "path_frame", Encode.string (pathFrameString frame) )
                                        , ( "pointer_type", Encode.string "mouse" )
                                        ]
                                     )
                                   ]
    in
    Encode.object withGesture


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
initialStateDecoder : Decoder RemoteState
initialStateDecoder =
    Decode.map8 RemoteState
        (Decode.field "board" (Decode.list CardStack.cardStackDecoder))
        (Decode.field "hands" (Decode.list handDecoder))
        (Decode.field "scores" (Decode.list Decode.int))
        (Decode.field "active_player_index" Decode.int)
        (Decode.field "turn_index" Decode.int)
        (Decode.field "deck" (Decode.list Card.cardDecoder))
        (Decode.field "cards_played_this_turn" Decode.int)
        (Decode.field "victor_awarded" Decode.bool)
        |> Decode.andThen
            (\partial ->
                Decode.map partial
                    (Decode.field "turn_start_board_score" Decode.int)
            )


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
