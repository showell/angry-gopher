module ReviewConfig exposing (config)

{-| `elm-review` configuration. Run with:

    npx elm-review            -- show findings
    npx elm-review --fix      -- auto-fix one finding at a time
    yes | npx elm-review --fix-all  -- auto-fix everything safe

This is the unified Elm project after the 2026-04-27
unification — both `src/Main.elm` (full-game client) and
`src/Puzzles.elm` (Puzzles gallery) compile from this directory.
elm-review sees everything, no cross-project false positives.

The auto-generated test files (DslConformanceTest,
PrimitivesConformanceTest) come from `cmd/fixturegen` and
would just regenerate any "fixes" away. Ignored.

elm-test exposes `suite` from each test module and runs them
through an auto-generated runner that elm-review can't see.
The Exports rule is exempted from `tests/`.

-}

import NoUnused.CustomTypeConstructorArgs
import NoUnused.CustomTypeConstructors
import NoUnused.Dependencies
import NoUnused.Exports
import NoUnused.Modules
import NoUnused.Parameters
import NoUnused.Patterns
import NoUnused.Variables
import Review.Rule exposing (Rule)


config : List Rule
config =
    let
        ignoreGenerated =
            Review.Rule.ignoreErrorsForFiles
                [ "tests/Game/DslConformanceTest.elm"
                , "tests/Game/PrimitivesConformanceTest.elm"
                ]

        ignoreTestExports =
            Review.Rule.ignoreErrorsForDirectories
                [ "tests/" ]
    in
    [ NoUnused.CustomTypeConstructors.rule [] |> ignoreGenerated
    , NoUnused.CustomTypeConstructorArgs.rule |> ignoreGenerated
    , NoUnused.Dependencies.rule
    , NoUnused.Exports.rule |> ignoreGenerated |> ignoreTestExports
    , NoUnused.Modules.rule |> ignoreGenerated |> ignoreTestExports
    , NoUnused.Parameters.rule |> ignoreGenerated
    , NoUnused.Patterns.rule |> ignoreGenerated
    , NoUnused.Variables.rule |> ignoreGenerated
    ]
