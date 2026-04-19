module Main.Wire exposing
    ( fetchActionLog
    , fetchNewSession
    , fetchRemoteState
    , sendAction
    , sendCompleteTurn
    )

{-| HTTP surface between the Elm client and the Gopher server.
Five outbound calls, plus the decoders that shape the inbound
responses. Each function produces `Cmd Msg` tagged with the
appropriate `Main.Msg` constructor so the `update` function
picks it up at the right branch.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.

## Design invariants

- **Client is authoritative on game state.** These calls are
  for persistence (sendAction, sendCompleteTurn), bootstrap
  (fetchNewSession, fetchRemoteState, fetchActionLog), and the
  one piece the client currently can't derive locally — the
  server's referee verdict on CompleteTurn. Nothing here is
  treated as authoritative beyond that boundary; the autonomous
  transition runs locally in `Main.Apply`.
- **No ports here.** `setSessionHash` lives in `Main.elm` (only
  port-modules may declare ports).
- **Decoders match server emission exactly.** If a field shape
  changes on the server, the decoder here must change; if it
  doesn't match, the HTTP response errors at decode time
  instead of silently half-succeeding.

-}

import Http
import Json.Decode as Decode exposing (Decoder)
import LynRummy.Card as Card
import LynRummy.CardStack as CardStack
import LynRummy.Hand exposing (Hand)
import LynRummy.PlayerTurn exposing (CompleteTurnResult(..))
import LynRummy.WireAction as WA exposing (WireAction)
import Main.Msg exposing (Msg(..))
import Main.State exposing (ActionLogBundle, CompleteTurnOutcome, RemoteState)



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


{-| Fetch the authoritative game state for a session. Called
once on session bootstrap (new session OR resume via URL hash)
to hydrate the client's Model. After that, all state changes
flow through `Main.Apply.applyWireAction` — this endpoint is
not consulted again during play.
-}
fetchRemoteState : Int -> Cmd Msg
fetchRemoteState sid =
    Http.get
        { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/state"
        , expect = Http.expectJson StateRefreshed remoteStateDecoder
        }


{-| Fetch the session's action log AND the pre-first-action
initial state. Used on session bootstrap so the client has both
the ammunition (log) and the baseline (initial state) to run a
faithful replay from — without relying on hardcoded Dealer
fixtures that may not match the session's actual seeded deal.
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
-}
sendAction : Int -> WireAction -> Cmd Msg
sendAction sessionId action =
    Http.post
        { url = "/gopher/lynrummy-elm/actions?session=" ++ String.fromInt sessionId
        , body = Http.jsonBody (WA.encode action)
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
        , body = Http.jsonBody (WA.encode WA.CompleteTurn)
        , expect = Http.expectStringResponse CompleteTurnResponded decodeCompleteTurnResponse
        }



-- INBOUND DECODERS


sessionIdDecoder : Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int


handDecoder : Decoder Hand
handDecoder =
    Decode.field "hand_cards" (Decode.list CardStack.handCardDecoder)
        |> Decode.map (\cards -> { handCards = cards })


{-| The /state endpoint returns `{session_id, seq, state: {...}}`.
The `state` object is the full game-state snapshot.
-}
remoteStateDecoder : Decoder RemoteState
remoteStateDecoder =
    Decode.field "state" innerStateDecoder


{-| Same shape as the inner `state` field of /state, but shared
with the /actions endpoint (which emits the initial-state
record at top level rather than nested).
-}
innerStateDecoder : Decoder RemoteState
innerStateDecoder =
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
        (Decode.field "initial_state" innerStateDecoder)
        (Decode.field "actions" (Decode.list WA.decoder))



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
