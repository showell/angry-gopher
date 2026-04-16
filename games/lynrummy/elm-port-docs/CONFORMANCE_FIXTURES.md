# Conformance fixtures (pointer)

The LynRummy referee conformance fixtures live in
`angry-gopher/lynrummy/conformance/`. The full spec, examples,
and loader contract are in that directory's `README.md`.

The Elm-side loader will live at
`elm-lynrummy/tests/LynRummy/ConformanceTest.elm` (TBD), reading
JSON fixtures from the angry-gopher path.

This file exists so a developer working in `elm-lynrummy` can
discover the conformance system without having to know it lives
in the other repo.
