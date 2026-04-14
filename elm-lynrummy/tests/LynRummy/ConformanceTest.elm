module LynRummy.ConformanceTest exposing (suite)

{-| Cross-language conformance fixtures, runner.

The fixtures live in angry-gopher/lynrummy/conformance/*.json. They
get baked into `LynRummy.Fixtures` by the generator at
angry-gopher/tools/gen_elm_fixtures.py (Elm 0.19 can't read files
at test time).

Each fixture is a (name, raw-JSON) pair. This runner parses the
JSON at test time — which also exercises the Elm JSON decoders.
Dispatch on the `operation` field selects which referee entry
point to call; the result is compared against `expected`.

-}

import Expect
import Json.Decode as D
import LynRummy.BoardGeometry exposing (BoardBounds, boardBoundsDecoder)
import LynRummy.CardStack exposing (CardStack, cardStackDecoder)
import LynRummy.Fixtures exposing (fixtures)
import LynRummy.Referee as Referee
    exposing
        ( RefereeError
        , RefereeMove
        , RefereeStage(..)
        , refereeMoveDecoder
        , refereeStageToString
        )
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Conformance fixtures"
        (List.map runFixture fixtures)


runFixture : ( String, String ) -> Test
runFixture ( name, rawJson ) =
    test name
        (\_ ->
            case D.decodeString envelopeDecoder rawJson of
                Err e ->
                    Expect.fail
                        (name ++ ": decode error: " ++ D.errorToString e)

                Ok fx ->
                    runOperation fx
        )



-- ENVELOPE


type alias Envelope =
    { operation : String
    , input : D.Value
    , bounds : BoardBounds
    , expected : Expected
    }


envelopeDecoder : D.Decoder Envelope
envelopeDecoder =
    D.map4 Envelope
        (D.field "operation" D.string)
        (D.field "input" D.value)
        (D.field "bounds" boardBoundsDecoder)
        (D.field "expected" expectedDecoder)



-- EXPECTED


type Expected
    = Pass
    | Fail { stage : String, messageSubstr : String }


expectedDecoder : D.Decoder Expected
expectedDecoder =
    D.field "ok" D.bool
        |> D.andThen
            (\ok ->
                if ok then
                    D.succeed Pass

                else
                    D.field "error"
                        (D.map2
                            (\s m -> Fail { stage = s, messageSubstr = m })
                            (D.field "stage" D.string)
                            (D.field "message_substr" D.string)
                        )
            )



-- DISPATCH


runOperation : Envelope -> Expect.Expectation
runOperation fx =
    case fx.operation of
        "validate_game_move" ->
            case D.decodeValue refereeMoveDecoder fx.input of
                Err e ->
                    Expect.fail ("move input decode: " ++ D.errorToString e)

                Ok move ->
                    assertResult fx.expected (Referee.validateGameMove move fx.bounds)

        "validate_turn_complete" ->
            case D.decodeValue (D.field "board" (D.list cardStackDecoder)) fx.input of
                Err e ->
                    Expect.fail ("board input decode: " ++ D.errorToString e)

                Ok board ->
                    assertResult fx.expected (Referee.validateTurnComplete board fx.bounds)

        other ->
            Expect.fail ("unknown operation: " ++ other)



-- ASSERT


assertResult : Expected -> Result RefereeError () -> Expect.Expectation
assertResult want got =
    case ( want, got ) of
        ( Pass, Ok () ) ->
            Expect.pass

        ( Pass, Err err ) ->
            Expect.fail
                ("expected ok, got "
                    ++ refereeStageToString err.stage
                    ++ ": "
                    ++ err.message
                )

        ( Fail f, Ok () ) ->
            Expect.fail ("expected error at stage " ++ f.stage ++ ", got ok")

        ( Fail f, Err err ) ->
            let
                gotStage =
                    refereeStageToString err.stage
            in
            if gotStage /= f.stage then
                Expect.fail
                    ("stage mismatch — want "
                        ++ f.stage
                        ++ ", got "
                        ++ gotStage
                        ++ " (message: "
                        ++ err.message
                        ++ ")"
                    )

            else if f.messageSubstr /= "" && not (String.contains f.messageSubstr err.message) then
                Expect.fail
                    ("message substring \""
                        ++ f.messageSubstr
                        ++ "\" not found in \""
                        ++ err.message
                        ++ "\""
                    )

            else
                Expect.pass
