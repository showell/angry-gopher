module Main.Wire exposing
    ( fetchActionLog
    , fetchNewSession
    , initialStateDecoder
    , sendAction
    , sendCompleteTurn
    , sendPuzzleAction
    )

{-| HTTP surface between the Elm client and the Gopher server.
Four outbound calls, plus the decoders that shape the inbound
responses. Each function produces `Cmd Msg` tagged with the
appropriate `Main.Msg` constructor so the `update` function
picks it up at the right branch.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.

## Design invariants

- **Client is authoritative on game state.** Elm derives
  current state locally from (initial_state + action log);
  these calls are for persistence (sendAction,
  sendCompleteTurn), session creation (fetchNewSession),
  and the one-time bootstrap fetch of the action log
  (fetchActionLog). No runtime wire read of current state;
  the server's responses on CompleteTurn are diagnostic,
  not gating.
- **No ports here.** `setSessionPath` lives in `Main.elm` (only
  port-modules may declare ports).
- **Decoders match server emission exactly.** If a field shape
  changes on the server, the decoder here must change; if it
  doesn't match, the HTTP response errors at decode time
  instead of silently half-succeeding.

-}

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Game.Card as Card
import Game.CardStack as CardStack
import Game.Hand exposing (Hand)
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.WireAction as WA exposing (WireAction)
import Main.Msg exposing (Msg(..))
import Game.Game exposing (CompleteTurnOutcome)
import Main.State exposing (ActionLogBundle, ActionLogEntry, GesturePoint, PathFrame(..), RemoteState)



-- OUTBOUND CALLS


{-| Create a new session on the server. The server generates a
deck seed, persists the session row, and returns the id. The
client then fetches /state to hydrate the initial game state
and sets the URL hash so reload resumes the same game.
-}
fetchNewSession : Cmd Msg
fetchNewSession =
    Http.post
        { url = "/gopher/lynrummy-elm/new-session"
        , body = Http.emptyBody
        , expect = Http.expectJson SessionReceived sessionIdDecoder
        }


{-| Fetch the session's action log AND the pre-first-action
initial state. The one-time bootstrap wire read: Elm uses
`initialState` + `actions` to reconstruct current state
locally via `Main.bootstrapFromBundle`. No separate /state
fetch; Elm owns derivation.
-}
fetchActionLog : Int -> Cmd Msg
fetchActionLog sid =
    Http.get
        { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/actions"
        , expect = Http.expectJson ActionLogFetched actionLogDecoder
        }


{-| Fire-and-forget wire-action submission. Used for every
action EXCEPT CompleteTurn — merge_hand, merge_stack, split,
move_stack, place_hand. Errors are currently ignored
(`ActionSent` handler is a no-op); server-side validation +
broadcast arrives with multiplayer.

`maybeGesture` carries the captured drag telemetry for the
wire. Pass `Nothing` for actions that didn't originate from a
drag (button clicks, replay-emitted, etc.) AND for hand-origin
drags (merge_hand, place_hand) — those always replay via
live DOM measurement, so shipping a captured path just serves
as dead weight. Intra-board drags pass `Just { path, frame =
BoardFrame }` after translating viewport samples to board
frame at the send boundary.
-}
sendAction : Int -> WireAction -> Maybe { path : List GesturePoint, frame : PathFrame } -> Cmd Msg
sendAction sessionId action maybeGesture =
    Http.post
        { url = "/gopher/lynrummy-elm/actions?session=" ++ String.fromInt sessionId
        , body = Http.jsonBody (encodeEnvelope action maybeGesture)
        , expect = Http.expectWhatever ActionSent
        }


{-| Lab-puzzle write path. Goes to /gopher/board-lab/actions
with `?session=<id>&puzzle=<name>`; the server appends to
`lynrummy_elm_puzzle_actions`. Same envelope shape as
`sendAction`. Same fire-and-forget contract.

Callers dispatch on `model.puzzleName`:

  - `Just name` → `sendPuzzleAction sid name action gesture`
  - `Nothing` → `sendAction sid action gesture`

The split exists because the two activity kinds (full-game vs.
puzzle attempts on a shared page-load) need different
disambiguators on the action row, and the schema split that
follows from "no nullable kind-discriminators" lands as two
endpoints.
-}
sendPuzzleAction :
    Int
    -> String
    -> WireAction
    -> Maybe { path : List GesturePoint, frame : PathFrame }
    -> Cmd Msg
sendPuzzleAction sessionId puzzleName action maybeGesture =
    Http.post
        { url =
            "/gopher/board-lab/actions?session="
                ++ String.fromInt sessionId
                ++ "&puzzle="
                ++ puzzleName
        , body = Http.jsonBody (encodeEnvelope action maybeGesture)
        , expect = Http.expectWhatever ActionSent
        }


{-| CompleteTurn needs the server's referee verdict (dirty-board
rejection) in the response, unlike fire-and-forget actions. A
200 with `turn_result:"success*"` is a committed turn; a 400
with `turn_result:"failure"` is the referee refusing a dirty
board. Both paths surface via `CompleteTurnResponded`.
-}
sendCompleteTurn : Int -> Cmd Msg
sendCompleteTurn sessionId =
    Http.post
        { url = "/gopher/lynrummy-elm/actions?session=" ++ String.fromInt sessionId
        , body = Http.jsonBody (encodeEnvelope WA.CompleteTurn Nothing)
        , expect = Http.expectStringResponse CompleteTurnResponded decodeCompleteTurnResponse
        }


pathFrameString : PathFrame -> String
pathFrameString frame =
    case frame of
        BoardFrame ->
            "board"

        ViewportFrame ->
            "viewport"



-- ENVELOPE


{-| Outbound POST body: `{"action": <WireAction>, "gesture_metadata": <optional>}`.
Server decodes both sibling fields. Keeps the action JSON clean
(no telemetry fields polluting `DecodeWireAction`) and leaves
headroom for later telemetry kinds (click timings, undos) to
drop in alongside `gesture_metadata` without touching
WireAction's shape.

When a gesture is present, emit the full metadata shape in
parity with Python's synthesizer: `path`, `path_frame`,
`pointer_type`. The caller has already translated the path's
samples into the named frame (typically `BoardFrame` for
intra-board drags — see `Main.Gesture.handleMouseUp`).
-}
encodeEnvelope : WireAction -> Maybe { path : List GesturePoint, frame : PathFrame } -> Value
encodeEnvelope action maybeGesture =
    case maybeGesture of
        Nothing ->
            Encode.object [ ( "action", WA.encode action ) ]

        Just { path, frame } ->
            case path of
                [] ->
                    Encode.object [ ( "action", WA.encode action ) ]

                _ ->
                    Encode.object
                        [ ( "action", WA.encode action )
                        , ( "gesture_metadata"
                          , Encode.object
                                [ ( "path", Encode.list encodeGesturePoint path )
                                , ( "path_frame", Encode.string (pathFrameString frame) )
                                , ( "pointer_type", Encode.string "mouse" )
                                ]
                          )
                        ]


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


{-| The game-state record as the server ships it. Same shape
whether nested inside an /actions bundle (full-game session
resume) or living alone in the lab catalog payload (lab puzzle
panels bootstrap from this directly). Exposed so the lab can
decode the initial state it already has in hand without a
round-trip.
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
        (Decode.field "initial_state" initialStateDecoder)
        (Decode.field "actions" (Decode.list actionLogEntryDecoder))


{-| Each action in `/actions` comes as the same envelope shape
as the inbound POST body:

    {"action": <WireAction>,
     "gesture_metadata": {"path": [...], "path_frame": "board"|"viewport"}}

Gesture metadata is pulled into `gesturePath` when present;
`path_frame` tags the coordinate frame those samples live in
(board = intra-board drag, translated at capture time so CSS
handles board→viewport at render time; viewport = hand-origin
or pre-translation live capture). Missing `path_frame`
defaults to viewport (back-compat with earlier captures that
didn't carry the tag).
-}
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



-- COMPLETETURN RESPONSE


{-| CompleteTurn uses `expectStringResponse` so we can decode
BOTH 200 (success variants) and 400 (failure) response bodies
— both share the `{turn_result, turn_score, cards_drawn,
dealt_cards}` shape that `completeTurnOutcomeDecoder` handles.
-}
decodeCompleteTurnResponse : Http.Response String -> Result Http.Error CompleteTurnOutcome
decodeCompleteTurnResponse response =
    case response of
        Http.BadUrl_ url ->
            Err (Http.BadUrl url)

        Http.Timeout_ ->
            Err Http.Timeout

        Http.NetworkError_ ->
            Err Http.NetworkError

        Http.BadStatus_ _ body ->
            -- 400 with {"turn_result":"failure",...} is the
            -- dirty-board rejection. Any other non-2xx is a
            -- real error.
            case Decode.decodeString completeTurnOutcomeDecoder body of
                Ok outcome ->
                    Ok outcome

                Err _ ->
                    Err (Http.BadBody body)

        Http.GoodStatus_ _ body ->
            case Decode.decodeString completeTurnOutcomeDecoder body of
                Ok outcome ->
                    Ok outcome

                Err decodeErr ->
                    Err (Http.BadBody (Decode.errorToString decodeErr))


completeTurnOutcomeDecoder : Decoder CompleteTurnOutcome
completeTurnOutcomeDecoder =
    Decode.map4 CompleteTurnOutcome
        turnResultDecoder
        (Decode.maybe (Decode.field "turn_score" Decode.int)
            |> Decode.map (Maybe.withDefault 0)
        )
        (Decode.maybe (Decode.field "cards_drawn" Decode.int)
            |> Decode.map (Maybe.withDefault 0)
        )
        (Decode.maybe (Decode.field "dealt_cards" (Decode.list Card.cardDecoder))
            |> Decode.map (Maybe.withDefault [])
        )


turnResultDecoder : Decoder CompleteTurnResult
turnResultDecoder =
    Decode.field "turn_result" Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "success" ->
                        Decode.succeed Success

                    "success_but_needs_cards" ->
                        Decode.succeed SuccessButNeedsCards

                    "success_as_victor" ->
                        Decode.succeed SuccessAsVictor

                    "success_with_hand_emptied" ->
                        Decode.succeed SuccessWithHandEmptied

                    "failure" ->
                        Decode.succeed Failure

                    other ->
                        Decode.fail ("unknown turn_result: " ++ other)
            )
