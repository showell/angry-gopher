module Test.AgentPlayBridge exposing
    ( clickWithEmptyPlan
    , clickWithNoPlan
    , clickWithPlanJson
    )

{-| Test-only bridge for the async agent-play port.

Phase 2 of TS_ELM_INTEGRATION moved `ClickAgentPlay` behind an
async engine port: the click emits an `EngineSolveRequested`
Output, the host (in production) fires the JS engine bundle,
and the result lands as an `EngineSolveResult` Msg. Tests
**don't run the JS bundle** — they don't need to. The logic
under test is the Elm-side click→cache→runBatch→Replay
pipeline; what plan an engine would produce for a given board
is irrelevant. So tests **provide their own plan** as part of
the scenario, and the bridge dispatches it.

API:

  - `clickWithPlanJson json m0` — click, then deliver an
    engine response carrying the given plan-JSON (a string of
    `[{line, wire_actions}, ...]`). Use this when the test
    asserts victory / replay drain over a real primitive
    sequence. Plans for non-trivial boards are typically
    captured once from a real engine.js run and pasted into
    the test as a multi-line string.
  - `clickWithEmptyPlan m0` — click, then deliver
    `plan: []`. Asserts the "already clean" branch.
  - `clickWithNoPlan m0` — click, then deliver
    `plan: null`. Asserts the "could not find a plan"
    branch.

Lives under `tests/` because production code never wants to
synthesize an engine response — only the Elm test layer
needs this when the JS bundle isn't in the loop.

-}

import Json.Decode as Decode
import Json.Encode as Encode
import Main.Msg exposing (Msg(..))
import Main.Play as Play
import Main.State exposing (Model)


{-| Click "Let agent play", then deliver a synthesized engine
response carrying the plan JSON the test specifies. The plan
JSON must be a JSON array of `{line, wire_actions}` objects —
the same shape `engine_glue.js` produces in production.

If the click doesn't fire the engine port (e.g. replay is
already running, or the agentProgram cache is live), the
plan is silently ignored — m1 already reflects the click's
post-state.
-}
clickWithPlanJson : String -> Model -> Model
clickWithPlanJson planJson m0 =
    let
        planValue =
            case Decode.decodeString Decode.value planJson of
                Ok v ->
                    v

                Err _ ->
                    Encode.null
    in
    deliverResponse m0 planValue


{-| Click "Let agent play", then deliver `plan: []`. -}
clickWithEmptyPlan : Model -> Model
clickWithEmptyPlan m0 =
    deliverResponse m0 (Encode.list identity [])


{-| Click "Let agent play", then deliver `plan: null`. -}
clickWithNoPlan : Model -> Model
clickWithNoPlan m0 =
    deliverResponse m0 Encode.null


deliverResponse : Model -> Encode.Value -> Model
deliverResponse m0 planValue =
    let
        ( m1, _, output ) =
            Play.update ClickAgentPlay m0
    in
    case output of
        Play.EngineSolveRequested payload ->
            let
                requestId =
                    extractRequestId payload

                response =
                    Encode.object
                        [ ( "request_id", Encode.int requestId )
                        , ( "op", Encode.string "agent_play" )
                        , ( "ok", Encode.bool True )
                        , ( "plan", planValue )
                        ]

                ( m2, _, _ ) =
                    Play.update (EngineSolveResult response) m1
            in
            m2

        _ ->
            m1


extractRequestId : Encode.Value -> Int
extractRequestId payload =
    case Decode.decodeValue (Decode.field "request_id" Decode.int) payload of
        Ok n ->
            n

        Err _ ->
            0
