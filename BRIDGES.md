# Bridges

Steve's framing of "redundancy as asset." Repeated work is a
liability when it's just copying; it's an asset when two
independent representations of the same thing are forced to
agree.

## What the paradigm requires

A bridge is only worth building if all four conditions hold:

1. **Two or more representations of the same thing.** Not
   copies — independent representations built via different
   mechanisms.
2. **A forced agreement check.** The representations must be
   verifiable against each other automatically, at build or
   test time.
3. **Independence of the implementations.** A bug shouldn't
   manifest identically in both representations. Sharing
   code between them defeats the bridge.
4. **Deliberate maintenance.** The bridge stays useful only
   while both representations are kept in sync — which means
   the project treats keeping them so as a first-class task.

Duplication that fails any of these four is just duplication.
A bridge that isn't checked is worse than no bridge: it's a
latent bug farm.

## Canonical example: the LynRummy DSL conformance harness

`games/lynrummy/conformance/scenarios/*.dsl` is a single set
of scenario files. `cmd/fixturegen` compiles them into two
independent test surfaces:

- An Elm test module:
  `games/lynrummy/elm/tests/Game/DslConformanceTest.elm`.
- A JSON fixture file the TS suite reads:
  `games/lynrummy/conformance/fixtures.json`, consumed by
  `games/lynrummy/ts/test/test_engine_conformance.ts`.

The Elm and TS sides implement the same engine independently
(no shared code), and both must pass scenario-by-scenario.
Divergent pass/fail counts are a hard failure surface — the
bridge fires when one side drifts from the other. The
`ops/check-conformance` script is the forced agreement check.

This is the load-bearing example: when adding a cross-
language behavior, build the bridge first (DSL scenarios +
runners on each side) and let the bridge enforce parity.

## See also

- [`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md)
  cites this paradigm as load-bearing for the cross-language
  layer.
