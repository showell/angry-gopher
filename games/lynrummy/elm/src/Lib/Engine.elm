module Lib.Engine exposing
    ( HintResponse(..)
    , buildGameHintRequest
    , decodeHintResponse
    )

{-| Elm ↔ JS engine wire. The JS engine bundle (TS-compiled,
loaded alongside elm.js) is the canonical solver; Elm sends
requests over a port and decodes responses. This module owns
the request-encoding / response-decoding shape; Main.Play
owns the Model bookkeeping (pendingEngineRequest counter,
status, hintedCards).

Request/response carry a `request_id` for stale-response
detection — Elm matches against the in-flight id and discards
mismatches. Future agent-play ops will join this module as
sibling builders / decoders sharing the same wire.

-}

import Lib.CardStack exposing (CardStack)
import Lib.Rules.Card as Card exposing (Card)
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
