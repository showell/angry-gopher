module Test.AgentPlayBridge exposing
    ( simulateClickAndDeliverPlan
    , simulateEngineResponseFor
    )

{-| Test-only bridge for the async agent-play port.

Phase 2 of TS_ELM_INTEGRATION moved `ClickAgentPlay` behind an
async engine port: the click emits an `EngineSolveRequested`
Output, the host fires the JS bundle's `agentPlay`, and the
result lands as an `EngineSolveResult` Msg. Tests can't run the
JS bundle, so we synthesize the engine response from the
**legacy Elm-BFS path** (`Game.Agent.Bfs.solveBoard` + the
existing verb / geometry pipeline). This faithfully reproduces
what the TS engine would have shipped over the wire, so test
assertions about the post-engine state stay meaningful.

`simulateClickAndDeliverPlan` is the one-call shorthand: dispatch
`ClickAgentPlay`, capture the requestId from the emitted Output,
synthesize a response, dispatch `EngineSolveResult` — return the
post-response model.

`simulateEngineResponseFor` is the lower-level building block —
exposed in case a test wants to inspect the intermediate
"Thinking…" model or the request payload.

Lives under `tests/` (not `src/`) because nothing in production
should be using the legacy BFS to fake the engine.

-}

import Game.Agent.Bfs as Bfs
import Game.Agent.GeometryPlan as AgentGeometry
import Game.Agent.Move as AgentMove
import Game.Agent.Verbs as AgentVerbs
import Game.CardStack exposing (CardStack)
import Game.WireAction as WA
import Json.Decode as Decode
import Json.Encode as Encode
import Main.Apply
import Main.Msg exposing (Msg(..))
import Main.Play as Play
import Main.State as State exposing (Model)


{-| Click the agent-play button, then immediately deliver an
engine-response message synthesized from the legacy Bfs path.
The intermediate state ("Thinking…") flashes by; the test sees
the post-response model.

Returns just the model — the Cmd / Output stream isn't used by
test assertions.
-}
simulateClickAndDeliverPlan : Model -> Model
simulateClickAndDeliverPlan m0 =
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
                    simulateEngineResponseFor requestId m0.board

                ( m2, _, _ ) =
                    Play.update (EngineSolveResult response) m1
            in
            m2

        _ ->
            -- No port fired (e.g. replay running, or cache live and
            -- consumed synchronously). m1 already reflects the
            -- post-click state.
            m1


{-| Build an engine_response payload (in the JSON shape the
production engine_glue.js produces) for the given requestId
and board. Computes the plan via legacy Elm BFS, expands each
move into primitives via the existing verb + geometry pipeline,
threading a sim board across moves.

The resulting JSON has the exact shape `Play.handleEngineSolveResult`
expects — request_id, op="agent_play", ok=true, plan as a list of
{line, wire_actions}. Returns ok=true with plan=null when BFS
finds nothing.
-}
simulateEngineResponseFor : Int -> List CardStack -> Encode.Value
simulateEngineResponseFor requestId board =
    let
        envelope plan =
            Encode.object
                [ ( "request_id", Encode.int requestId )
                , ( "op", Encode.string "agent_play" )
                , ( "ok", Encode.bool True )
                , ( "plan", plan )
                ]
    in
    case Bfs.solveBoard board of
        Nothing ->
            envelope Encode.null

        Just plan ->
            envelope (Encode.list identity (encodeBatches board plan))


encodeBatches : List CardStack -> List AgentMove.Move -> List Encode.Value
encodeBatches initialBoard plan =
    let
        loop sim moves acc =
            case moves of
                [] ->
                    List.reverse acc

                move :: rest ->
                    let
                        primitives =
                            AgentVerbs.moveToPrimitives sim move
                                |> AgentGeometry.planActions sim

                        nextSim =
                            List.foldl applyPrimitive sim primitives

                        encoded =
                            Encode.object
                                [ ( "line", Encode.string (AgentMove.describe move) )
                                , ( "wire_actions"
                                  , Encode.list WA.encode primitives
                                  )
                                ]
                    in
                    loop nextSim rest (encoded :: acc)
    in
    loop initialBoard plan []


applyPrimitive : WA.WireAction -> List CardStack -> List CardStack
applyPrimitive prim board =
    let
        base =
            State.baseModel

        outcome =
            Main.Apply.applyAction prim { base | board = board }
    in
    outcome.model.board


extractRequestId : Encode.Value -> Int
extractRequestId payload =
    case Decode.decodeValue (Decode.field "request_id" Decode.int) payload of
        Ok n ->
            n

        Err _ ->
            0
