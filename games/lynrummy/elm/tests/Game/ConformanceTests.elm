module Game.ConformanceTests exposing (suite)

{-| End-to-end conformance test runner.

Parses every embedded `.dsl` file in `Game.DslContent.allFiles`
via `Game.ConformanceDsl.parseConformanceDsl`, then dispatches
each scenario to its op-specific verifier. Verifiers are
hand-written Elm functions in this module (formerly emitted
as templated Elm code from `cmd/fixturegen`).

Phase 3 of the DSL retirement: as each op gets a real
verifier, scenarios that op covers stop being `Expect.pass`
stubs and start asserting real behavior. The legacy
`DslConformanceTest.elm` still covers everything during the
transition; once all ops are ported here, that file (and
the Elm-emit code in `cmd/fixturegen`) goes away.

-}

import Expect
import Game.ConformanceDsl as Dsl
import Game.DslContent
import Game.Physics.BoardGeometry as BoardGeometry
import Test exposing (Test, describe, test)


suite : Test
suite =
    let
        scenarios =
            Game.DslContent.allFiles
                |> List.concatMap (\( _, text ) -> Dsl.parseConformanceDsl text)
    in
    describe "Conformance"
        (List.map scenarioTest scenarios)


scenarioTest : Dsl.Scenario -> Test
scenarioTest sc =
    test sc.name (\_ -> verify sc)


verify : Dsl.Scenario -> Expect.Expectation
verify sc =
    case sc.op of
        "stack_height_constant" ->
            BoardGeometry.stackHeight |> Expect.equal 40

        _ ->
            -- Verifier not yet ported from fixturegen. The legacy
            -- DslConformanceTest.elm still covers this op.
            Expect.pass
