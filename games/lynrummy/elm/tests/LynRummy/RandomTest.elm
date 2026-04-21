module LynRummy.RandomTest exposing (suite)

{-| Tests for `LynRummy.Random`. Applies insight #19
(shared-fixture equivalence): expected values were captured
from the TS source with `seed=42` and pasted here as hard-coded
expectations. If the Elm port's mulberry32 is byte-identical
to the TS version, these tests pass. If any bit diverges, they
fail with precise diagnostics.

Reference capture script:

    function seeded_rand(seed) {
        let t = seed >>> 0;
        return function () {
            t = (t + 0x6D2B79F5) >>> 0;
            let r = Math.imul(t ^ (t >>> 15), 1 | t);
            r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
            return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
        };
    }
    const r = seeded_rand(42);
    for (let i = 0; i < 8; i++) console.log(r());

-}

import Expect
import LynRummy.Random as R
import Test exposing (Test, describe, test)



-- SUITE


suite : Test
suite =
    describe "LynRummy.Random (mulberry32 shared fixtures)"
        [ nextFloatFixtures
        , nextIntFixtures
        , shuffleFixtures
        , structuralTests
        ]



-- Capture n floats starting from the given seed.


captureFloats : Int -> R.Seed -> List Float
captureFloats n seed =
    captureFloatsHelp n seed []


captureFloatsHelp : Int -> R.Seed -> List Float -> List Float
captureFloatsHelp n seed acc =
    if n <= 0 then
        List.reverse acc

    else
        let
            ( f, s ) =
                R.next seed
        in
        captureFloatsHelp (n - 1) s (f :: acc)


nextFloatFixtures : Test
nextFloatFixtures =
    test "seed=42 produces the exact TS reference sequence (8 floats)" <|
        \_ ->
            let
                expected =
                    [ 0.6011037519201636
                    , 0.44829055899754167
                    , 0.8524657934904099
                    , 0.6697340414393693
                    , 0.17481389874592423
                    , 0.5265925421845168
                    , 0.2732279943302274
                    , 0.6247446539346129
                    ]

                actual =
                    captureFloats 8 (R.initSeed 42)
            in
            Expect.equal expected actual



-- nextInt fixtures: from seed 42, call nextInt with n=2,3,4,...10
-- and compare to TS's Math.floor(r() * n) outputs.


captureInts : List Int -> R.Seed -> List Int
captureInts ns seed0 =
    let
        go ns_ seed acc =
            case ns_ of
                [] ->
                    List.reverse acc

                n :: rest ->
                    let
                        ( i, s ) =
                            R.nextInt n seed
                    in
                    go rest s (i :: acc)
    in
    go ns seed0 []


nextIntFixtures : Test
nextIntFixtures =
    test "seed=42 nextInt sequence (n=2..10) matches TS reference" <|
        \_ ->
            let
                ns =
                    [ 2, 3, 4, 5, 6, 7, 8, 9, 10 ]

                expected =
                    [ 1, 1, 3, 3, 1, 3, 2, 5, 8 ]

                actual =
                    captureInts ns (R.initSeed 42)
            in
            Expect.equal expected actual



-- Fisher-Yates shuffle fixture.


shuffleFixtures : Test
shuffleFixtures =
    test "seed=42 shuffle of [0..9] matches TS reference" <|
        \_ ->
            let
                expected =
                    [ 0, 7, 3, 5, 2, 1, 8, 9, 4, 6 ]

                ( actual, _ ) =
                    R.shuffle (R.initSeed 42) (List.range 0 9)
            in
            Expect.equal expected actual



-- Structural tests (beyond the TS fixtures) for Elm-side sanity.


structuralTests : Test
structuralTests =
    describe "structural properties"
        [ test "initSeed followed by next returns a float in [0, 1)" <|
            \_ ->
                let
                    ( f, _ ) =
                        R.next (R.initSeed 1)
                in
                Expect.all
                    [ (\x -> x >= 0) >> Expect.equal True
                    , (\x -> x < 1) >> Expect.equal True
                    ]
                    f
        , test "nextInt is deterministic: same seed -> same output" <|
            \_ ->
                let
                    ( a, _ ) =
                        R.nextInt 100 (R.initSeed 7)

                    ( b, _ ) =
                        R.nextInt 100 (R.initSeed 7)
                in
                Expect.equal a b
        , test "shuffle preserves all elements (just reorders)" <|
            \_ ->
                let
                    input =
                        List.range 0 19

                    ( shuffled, _ ) =
                        R.shuffle (R.initSeed 123) input
                in
                Expect.equal (List.sort input) (List.sort shuffled)
        , test "shuffle of empty list returns empty" <|
            \_ ->
                let
                    emptyInts : List Int
                    emptyInts =
                        []

                    ( out, _ ) =
                        R.shuffle (R.initSeed 1) emptyInts
                in
                Expect.equal [] out
        ]
