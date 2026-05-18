module Lib.Engine exposing
    ( AgentStep
    , AgentStepResponse(..)
    , HintResponse(..)
    , buildAgentStepRequest
    , buildGameHintRequest
    , decodeAgentStepResponse
    , decodeHintResponse
    )

{-| Elm ↔ JS engine wire. The JS engine bundle (TS-compiled,
loaded alongside elm.js) is the canonical solver; Elm sends
requests over a port and decodes responses. This module owns
the request-encoding / response-decoding shape; Game.Play
owns the Model bookkeeping (pendingEngineRequest counter,
status, hintedCards).

Two ops live here today:

  - `game_hint`     — Hint button. Text-only response.
  - `agent_step`    — one play of real-time agent play.
                      Response is a primitive-DSL string the
                      caller parses + animates.

Request/response carry a `request_id` for stale-response
detection — Elm matches against the in-flight id and discards
mismatches.

-}

import Lib.BoardDsl as BoardDsl
import Lib.CardStack exposing (CardStack)
import Lib.GameEvent exposing (GameEvent)
import Lib.Rules.Card as Card exposing (Card)
import Lib.WireAction as WireAction
import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)


{-| Decoded shape of a `game_hint` response. The `StaleId`
variant signals that the response was for an earlier request
the user has since superseded — caller should drop it.
-}
type HintResponse
    = HintLines (List String)
    | HintError String
    | HintStaleId
    | HintDecodeError String


{-| Build the `game_hint` request payload — sent over the
`engineRequest` port. The engine replies on `gameHintResponse`
with the matching `request_id`.
-}
buildGameHintRequest : Int -> List Card -> List CardStack -> Value
buildGameHintRequest reqId hand board =
    Encode.object
        [ ( "request_id", Encode.int reqId )
        , ( "op", Encode.string "game_hint" )
        , ( "hand", Encode.list Card.encodeCard hand )
        , ( "board", encodeBoardForEngine board )
        ]


{-| Encode the board into the snake_case shape the JS engine
expects: a list of stacks, each a list of `{value, suit, origin_deck}`
card objects.
-}
encodeBoardForEngine : List CardStack -> Value
encodeBoardForEngine board =
    Encode.list
        (\stack ->
            Encode.list Card.encodeCard
                (List.map .card stack.boardCards)
        )
        board


{-| Decode a `game_hint` response value. Pass the currently-
in-flight request id; the decoder checks that the response's
`request_id` matches and emits `HintStaleId` otherwise.
-}
decodeHintResponse : Maybe Int -> Value -> HintResponse
decodeHintResponse pendingId value =
    let
        envelopeDecoder =
            Decode.map3 (\rid ok mLines -> { rid = rid, ok = ok, lines = mLines })
                (Decode.field "request_id" Decode.int)
                (Decode.field "ok" Decode.bool)
                (Decode.maybe (Decode.field "lines" (Decode.list Decode.string)))

        errDecoder =
            Decode.field "error" Decode.string
    in
    case Decode.decodeValue envelopeDecoder value of
        Err err ->
            HintDecodeError (Decode.errorToString err)

        Ok r ->
            if pendingId /= Just r.rid then
                HintStaleId

            else if not r.ok then
                let
                    detail =
                        Decode.decodeValue errDecoder value
                            |> Result.withDefault "(no detail)"
                in
                HintError detail

            else
                HintLines (Maybe.withDefault [] r.lines)



-- ---- AGENT_STEP ------------------------------------------------------


{-| One agent move with both the parsed event (for animating)
and the raw DSL line (for forwarding to actions.dsl with a seq
prefix). Pairing them prevents the lists from drifting out of
sync.
-}
type alias AgentStep =
    { event : GameEvent
    , dsl : String
    }


{-| Decoded shape of an `agent_step` response.

  - `AgentStepEvents` carries the parsed primitive sequence for
    one play. Empty list = the agent yielded a stuck/end signal
    (the TS side returned ""); callers treat that as
    end-of-turn.
  - `AgentStepError` carries the engine's error string when
    `ok` is false.
  - `AgentStepStaleId` signals that the response was for an
    earlier request — caller should drop it.
  - `AgentStepDecodeError` covers shape mismatches.

-}
type AgentStepResponse
    = AgentStepEvents (List AgentStep)
    | AgentStepError String
    | AgentStepStaleId
    | AgentStepDecodeError String


{-| Build the `agent_step` request payload. Board and hand are
serialized to the canonical DSL on the way out — same shape the
TS conformance corpus uses, parsed by the engine's
`elmAgentStep` wrapper.
-}
buildAgentStepRequest : Int -> List CardStack -> List Card -> Value
buildAgentStepRequest reqId board hand =
    Encode.object
        [ ( "request_id", Encode.int reqId )
        , ( "op", Encode.string "agent_step" )
        , ( "board_dsl", Encode.string (BoardDsl.formatBoard board) )
        , ( "hand_dsl", Encode.string (formatHandLine hand) )
        ]


formatHandLine : List Card -> String
formatHandLine hand =
    String.join " " (List.map Card.cardStr hand)


{-| Decode an `agent_step` response. Splits the returned DSL
string into lines and parses each through `Lib.WireAction.parseEvent`.
-}
decodeAgentStepResponse : Maybe Int -> Value -> AgentStepResponse
decodeAgentStepResponse pendingId value =
    let
        envelopeDecoder =
            Decode.map3 (\rid ok mDsl -> { rid = rid, ok = ok, dsl = mDsl })
                (Decode.field "request_id" Decode.int)
                (Decode.field "ok" Decode.bool)
                (Decode.maybe (Decode.field "primitives_dsl" Decode.string))

        errDecoder =
            Decode.field "error" Decode.string
    in
    case Decode.decodeValue envelopeDecoder value of
        Err err ->
            AgentStepDecodeError (Decode.errorToString err)

        Ok r ->
            if pendingId /= Just r.rid then
                AgentStepStaleId

            else if not r.ok then
                let
                    detail =
                        Decode.decodeValue errDecoder value
                            |> Result.withDefault "(no detail)"
                in
                AgentStepError detail

            else
                parseEventLines (Maybe.withDefault "" r.dsl)


parseEventLines : String -> AgentStepResponse
parseEventLines dsl =
    let
        lines =
            String.lines dsl
                |> List.map String.trim
                |> List.filter (\s -> s /= "")

        parseOne line =
            WireAction.parseEvent line
                |> Result.map (\event -> { event = event, dsl = line })
    in
    case foldResults (List.map parseOne lines) of
        Ok steps ->
            AgentStepEvents steps

        Err msg ->
            AgentStepDecodeError ("primitive DSL parse: " ++ msg)


foldResults : List (Result String a) -> Result String (List a)
foldResults =
    List.foldr
        (\r acc ->
            case ( r, acc ) of
                ( Ok x, Ok xs ) ->
                    Ok (x :: xs)

                ( Err e, _ ) ->
                    Err e

                ( _, Err e ) ->
                    Err e
        )
        (Ok [])
