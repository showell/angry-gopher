module Lib.ConformanceDslTest exposing (suite)

{-| Smoke tests for the conformance DSL parser. Embeds a
representative sample of real .dsl content as a String and
verifies the parser handles each grammar shape we plan to
consume.

The samples are real scenarios pulled from the largest
TS-routed file (baseline_board_81.dsl, ~1200 lines / 81
scenarios) so the parser is exercised at realistic scale at
test time.

-}

import Dict exposing (Dict)
import Expect
import Lib.ConformanceDsl as D exposing (Expect(..), ExpectField(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "ConformanceDsl"
        [ smallSampleTests
        , scaleSmoke
        ]



-- SMALL SAMPLES — one scenario per grammar shape


smallSampleTests : Test
smallSampleTests =
    describe "grammar shapes"
        [ test "solve scenario with expect: no_plan shorthand" <|
            \_ ->
                let
                    src =
                        """
scenario baseline_board_ACp
  desc: Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): AC'
  expect: no_plan
"""
                in
                case D.parseConformanceDsl src of
                    [ sc ] ->
                        Expect.all
                            [ \s -> s.name |> Expect.equal "baseline_board_ACp"
                            , \s -> s.op |> Expect.equal "solve"
                            , \s -> List.length s.helper |> Expect.equal 1
                            , \s -> List.length s.trouble |> Expect.equal 1
                            , \s ->
                                case s.expect of
                                    ExpectScalar v ->
                                        v |> Expect.equal "no_plan"

                                    _ ->
                                        Expect.fail "expected ExpectScalar no_plan"
                            ]
                            sc

                    other ->
                        Expect.fail
                            ("expected 1 scenario, got " ++ String.fromInt (List.length other))
        , test "solve with plan_lines block" <|
            \_ ->
                let
                    src =
                        """
scenario baseline_board_3C
  desc: 4-step plan.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 3C
  expect:
    plan_lines:
      - "peel 2C from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [3C] → [2C 3C]"
      - "steal AC from HELPER [AC AD AH]"
"""
                in
                case D.parseConformanceDsl src of
                    [ sc ] ->
                        case sc.expect of
                            ExpectBlock dict ->
                                case dict |> blockField "plan_lines" of
                                    Just (ExpectLines lines) ->
                                        List.length lines |> Expect.equal 2

                                    _ ->
                                        Expect.fail "expected plan_lines as ExpectLines"

                            _ ->
                                Expect.fail "expected ExpectBlock"

                    _ ->
                        Expect.fail "expected 1 scenario"
        , test "find_open_loc scenario with loc expectation" <|
            \_ ->
                let
                    src =
                        """
scenario find_open_loc_empty_board
  desc: empty board, preferred origin.
  op: find_open_loc
  existing:
  card_count: 3
  expect:
    loc: (26, 26)
"""
                in
                case D.parseConformanceDsl src of
                    [ sc ] ->
                        Expect.all
                            [ \s -> s.op |> Expect.equal "find_open_loc"
                            , \s -> s.cardCount |> Expect.equal (Just 3)
                            , \s ->
                                case s.expect of
                                    ExpectBlock dict ->
                                        case dict |> blockField "loc" of
                                            Just (ExpectLoc loc) ->
                                                loc |> Expect.equal { top = 26, left = 26 }

                                            _ ->
                                                Expect.fail "expected ExpectLoc"

                                    _ ->
                                        Expect.fail "expected ExpectBlock"
                            ]
                            sc

                    _ ->
                        Expect.fail "expected 1 scenario"
        , test "hint_for_hand scenario with `- cards` board form" <|
            \_ ->
                let
                    src =
                        """
scenario triple_in_hand_with_dirty_board_returns_no_hint
  desc: dirty-board test.
  op: hint_for_hand
  hand: 7D 8D 9D
  board:
    - 5C 6C
  expect_steps:
"""
                in
                case D.parseConformanceDsl src of
                    [ sc ] ->
                        Expect.all
                            [ \s -> s.op |> Expect.equal "hint_for_hand"
                            , \s -> List.length s.hand |> Expect.equal 3
                            , \s -> List.length s.hintBoard |> Expect.equal 1
                            , \s -> List.length s.hintSteps |> Expect.equal 0
                            ]
                            sc

                    _ ->
                        Expect.fail "expected 1 scenario"
        , test "validate_board_geometry with full board + classification expect" <|
            \_ ->
                let
                    src =
                        """
scenario clean_3stack_board
  desc: three legal stacks, fully spaced.
  op: classify_board_geometry
  board:
    at (0,0): AC AD AH
    at (0,100): KH KS KD
    at (100,0): 5H 6H 7H
  expect:
    kind: CleanlySpaced
"""
                in
                case D.parseConformanceDsl src of
                    [ sc ] ->
                        Expect.all
                            [ \s -> s.op |> Expect.equal "classify_board_geometry"
                            , \s -> List.length s.board |> Expect.equal 3
                            , \s ->
                                case s.expect of
                                    ExpectBlock dict ->
                                        case dict |> blockField "kind" of
                                            Just (ExpectStr v) ->
                                                v |> Expect.equal "CleanlySpaced"

                                            _ ->
                                                Expect.fail "expected ExpectStr kind"

                                    _ ->
                                        Expect.fail "expected ExpectBlock"
                            ]
                            sc

                    _ ->
                        Expect.fail "expected 1 scenario"
        ]



-- SCALE SMOKE — embed a chunk of the biggest TS-routed file
-- and ensure the parser produces the expected scenario count
-- without errors. Acts as a timing canary too.


scaleSmoke : Test
scaleSmoke =
    describe "scale smoke"
        [ test "parses 10 baseline_board scenarios in one shot" <|
            \_ ->
                let
                    scenarios =
                        D.parseConformanceDsl baselineBoardSampleSrc
                in
                List.length scenarios |> Expect.equal 10
        , test "parses the full baseline_board_81.dsl (81 scenarios, ~30 KB)" <|
            \_ ->
                let
                    scenarios =
                        D.parseConformanceDsl baselineBoardFullSrc
                in
                List.length scenarios |> Expect.equal 81
        ]


baselineBoardSampleSrc : String
baselineBoardSampleSrc =
    """
scenario baseline_board_ACp
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
  trouble:
    at (0,0): AC'
  expect: no_plan

scenario baseline_board_2Cp
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 2C'
  expect: no_plan

scenario baseline_board_3C
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 3C
  expect:
    plan_lines:
      - "peel 2C from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [3C] → [2C 3C]"

scenario baseline_board_3Cp
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 3C'
  expect:
    plan_lines:
      - "peel 2C from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [3C'] → [2C 3C']"

scenario baseline_board_4Cp
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 4C'
  expect:
    plan_lines:
      - "splice [4C'] into HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C'] + [4C 5H 6S 7H]"

scenario baseline_board_5C
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 5C
  expect: no_plan

scenario baseline_board_6C
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 6C
  expect: no_plan

scenario baseline_board_7C
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 7C
  expect: no_plan

scenario baseline_board_8C
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 8C
  expect:
    plan_lines:
      - "push [8C] onto HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5H 6S 7H 8C]"

scenario baseline_board_9C
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
  trouble:
    at (0,0): 9C
  expect: no_plan
"""


blockField : String -> Dict String ExpectField -> Maybe ExpectField
blockField =
    Dict.get
baselineBoardFullSrc : String
baselineBoardFullSrc =
    """# AUTO-GENERATED by tools/gen_baseline_board.py. Do not hand-edit.
# Baseline suite: Game 17 board (6 helpers, 23 cards),
# one trouble singleton per remaining card in the double deck (81 total).
# Re-run the generator after solver changes, then commit both outputs.

scenario baseline_board_ACp
  desc: Baseline board, trouble AC'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): AC'
  expect: no_plan

scenario baseline_board_2Cp
  desc: Baseline board, trouble 2C'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 2C'
  expect: no_plan

scenario baseline_board_3C
  desc: Baseline board, trouble 3C. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 3C
  expect:
    plan_lines:
      - "peel 2C from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [3C] → [2C 3C]"
      - "steal AC from HELPER [AC AD AH], absorb onto [2C 3C] → [AC 2C 3C] [→COMPLETE] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [TD JD QD KD] → [TD JD QD KD AD]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"

scenario baseline_board_3Cp
  desc: Baseline board, trouble 3C'. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 3C'
  expect:
    plan_lines:
      - "peel 2C from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [3C'] → [2C 3C']"
      - "steal AC from HELPER [AC AD AH], absorb onto [2C 3C'] → [AC 2C 3C'] [→COMPLETE] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [TD JD QD KD] → [TD JD QD KD AD]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"

scenario baseline_board_4Cp
  desc: Baseline board, trouble 4C'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 4C'
  expect:
    plan_lines:
      - "splice [4C'] into HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C'] + [4C 5H 6S 7H]"

scenario baseline_board_5C
  desc: Baseline board, trouble 5C. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5C
  expect: no_plan

scenario baseline_board_5Cp
  desc: Baseline board, trouble 5C'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5C'
  expect: no_plan

scenario baseline_board_6C
  desc: Baseline board, trouble 6C. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6C
  expect: no_plan

scenario baseline_board_6Cp
  desc: Baseline board, trouble 6C'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6C'
  expect: no_plan

scenario baseline_board_7Cp
  desc: Baseline board, trouble 7C'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 7C'
  expect: no_plan

scenario baseline_board_8C
  desc: Baseline board, trouble 8C. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8C
  expect:
    plan_lines:
      - "push [8C] onto HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5H 6S 7H 8C]"

scenario baseline_board_8Cp
  desc: Baseline board, trouble 8C'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8C'
  expect:
    plan_lines:
      - "push [8C'] onto HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5H 6S 7H 8C']"

scenario baseline_board_9C
  desc: Baseline board, trouble 9C. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9C
  expect: no_plan

scenario baseline_board_9Cp
  desc: Baseline board, trouble 9C'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9C'
  expect: no_plan

scenario baseline_board_TC
  desc: Baseline board, trouble TC. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TC
  expect: no_plan

scenario baseline_board_TCp
  desc: Baseline board, trouble TC'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TC'
  expect: no_plan

scenario baseline_board_JC
  desc: Baseline board, trouble JC. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JC
  expect: no_plan

scenario baseline_board_JCp
  desc: Baseline board, trouble JC'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JC'
  expect: no_plan

scenario baseline_board_QC
  desc: Baseline board, trouble QC. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QC
  expect:
    plan_lines:
      - "peel KD from HELPER [TD JD QD KD], absorb onto [QC] → [QC KD]"
      - "steal AC from HELPER [AC AD AH], absorb onto [QC KD] → [QC KD AC] [→COMPLETE] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [2C 3D 4C 5H 6S 7H] → [AD 2C 3D 4C 5H 6S 7H]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"

scenario baseline_board_QCp
  desc: Baseline board, trouble QC'. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QC'
  expect:
    plan_lines:
      - "peel KD from HELPER [TD JD QD KD], absorb onto [QC'] → [QC' KD]"
      - "steal AC from HELPER [AC AD AH], absorb onto [QC' KD] → [QC' KD AC] [→COMPLETE] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [2C 3D 4C 5H 6S 7H] → [AD 2C 3D 4C 5H 6S 7H]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"

scenario baseline_board_KC
  desc: Baseline board, trouble KC. 2-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): KC
  expect:
    plan_lines:
      - "peel KD from HELPER [TD JD QD KD], absorb onto [KC] → [KC KD]"
      - "peel KS from HELPER [KS AS 2S 3S], absorb onto [KC KD] → [KS KC KD] [→COMPLETE]"

scenario baseline_board_KCp
  desc: Baseline board, trouble KC'. 2-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): KC'
  expect:
    plan_lines:
      - "peel KD from HELPER [TD JD QD KD], absorb onto [KC'] → [KC' KD]"
      - "peel KS from HELPER [KS AS 2S 3S], absorb onto [KC' KD] → [KS KC' KD] [→COMPLETE]"

scenario baseline_board_ADp
  desc: Baseline board, trouble AD'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): AD'
  expect:
    plan_lines:
      - "push [AD'] onto HELPER [TD JD QD KD] → [TD JD QD KD AD']"

scenario baseline_board_2D
  desc: Baseline board, trouble 2D. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 2D
  expect:
    plan_lines:
      - "steal AC from HELPER [AC AD AH], absorb onto [2D] → [AC 2D] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [TD JD QD KD] → [TD JD QD KD AD]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"
      - "peel 3S from HELPER [KS AS 2S 3S], absorb onto [AC 2D] → [AC 2D 3S] [→COMPLETE]"

scenario baseline_board_2Dp
  desc: Baseline board, trouble 2D'. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 2D'
  expect:
    plan_lines:
      - "steal AC from HELPER [AC AD AH], absorb onto [2D'] → [AC 2D'] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [TD JD QD KD] → [TD JD QD KD AD]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"
      - "peel 3S from HELPER [KS AS 2S 3S], absorb onto [AC 2D'] → [AC 2D' 3S] [→COMPLETE]"

scenario baseline_board_3Dp
  desc: Baseline board, trouble 3D'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 3D'
  expect: no_plan

scenario baseline_board_4D
  desc: Baseline board, trouble 4D. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 4D
  expect: no_plan

scenario baseline_board_4Dp
  desc: Baseline board, trouble 4D'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 4D'
  expect: no_plan

scenario baseline_board_5D
  desc: Baseline board, trouble 5D. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5D
  expect:
    plan_lines:
      - "splice [5D] into HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5D] + [5H 6S 7H]"

scenario baseline_board_5Dp
  desc: Baseline board, trouble 5D'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5D'
  expect:
    plan_lines:
      - "splice [5D'] into HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5D'] + [5H 6S 7H]"

scenario baseline_board_6D
  desc: Baseline board, trouble 6D. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6D
  expect: no_plan

scenario baseline_board_6Dp
  desc: Baseline board, trouble 6D'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6D'
  expect: no_plan

scenario baseline_board_7Dp
  desc: Baseline board, trouble 7D'. 3-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 7D'
  expect:
    plan_lines:
      - "yank 6S from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [7D'] → [6S 7D'] ; spawn [7H]"
      - "push [7H] onto HELPER [7S 7D 7C] → [7S 7D 7C 7H]"
      - "peel 5H from HELPER [2C 3D 4C 5H], absorb onto [6S 7D'] → [5H 6S 7D'] [→COMPLETE]"

scenario baseline_board_8D
  desc: Baseline board, trouble 8D. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8D
  expect: no_plan

scenario baseline_board_8Dp
  desc: Baseline board, trouble 8D'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8D'
  expect: no_plan

scenario baseline_board_9D
  desc: Baseline board, trouble 9D. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9D
  expect:
    plan_lines:
      - "push [9D] onto HELPER [TD JD QD KD] → [9D TD JD QD KD]"

scenario baseline_board_9Dp
  desc: Baseline board, trouble 9D'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9D'
  expect:
    plan_lines:
      - "push [9D'] onto HELPER [TD JD QD KD] → [9D' TD JD QD KD]"

scenario baseline_board_TDp
  desc: Baseline board, trouble TD'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TD'
  expect: no_plan

scenario baseline_board_JDp
  desc: Baseline board, trouble JD'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JD'
  expect: no_plan

scenario baseline_board_QDp
  desc: Baseline board, trouble QD'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QD'
  expect: no_plan

scenario baseline_board_KDp
  desc: Baseline board, trouble KD'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): KD'
  expect: no_plan

scenario baseline_board_ASp
  desc: Baseline board, trouble AS'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): AS'
  expect:
    plan_lines:
      - "push [AS'] onto HELPER [AC AD AH] → [AC AD AH AS']"

scenario baseline_board_2Sp
  desc: Baseline board, trouble 2S'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 2S'
  expect: no_plan

scenario baseline_board_3Sp
  desc: Baseline board, trouble 3S'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 3S'
  expect: no_plan

scenario baseline_board_4S
  desc: Baseline board, trouble 4S. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 4S
  expect:
    plan_lines:
      - "push [4S] onto HELPER [KS AS 2S 3S] → [KS AS 2S 3S 4S]"

scenario baseline_board_4Sp
  desc: Baseline board, trouble 4S'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 4S'
  expect:
    plan_lines:
      - "push [4S'] onto HELPER [KS AS 2S 3S] → [KS AS 2S 3S 4S']"

scenario baseline_board_5S
  desc: Baseline board, trouble 5S. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5S
  expect:
    plan_lines:
      - "yank 6S from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [5S] → [5S 6S] ; spawn [7H]"
      - "push [7H] onto HELPER [7S 7D 7C] → [7S 7D 7C 7H]"
      - "peel 7S from HELPER [7S 7D 7C 7H], absorb onto [5S 6S] → [5S 6S 7S] [→COMPLETE]"

scenario baseline_board_5Sp
  desc: Baseline board, trouble 5S'. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5S'
  expect:
    plan_lines:
      - "yank 6S from HELPER [2C 3D 4C 5H 6S 7H], absorb onto [5S'] → [5S' 6S] ; spawn [7H]"
      - "push [7H] onto HELPER [7S 7D 7C] → [7S 7D 7C 7H]"
      - "peel 7S from HELPER [7S 7D 7C 7H], absorb onto [5S' 6S] → [5S' 6S 7S] [→COMPLETE]"

scenario baseline_board_6Sp
  desc: Baseline board, trouble 6S'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6S'
  expect: no_plan

scenario baseline_board_7Sp
  desc: Baseline board, trouble 7S'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 7S'
  expect: no_plan

scenario baseline_board_8S
  desc: Baseline board, trouble 8S. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8S
  expect:
    plan_lines:
      - "push [8S] onto HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5H 6S 7H 8S]"

scenario baseline_board_8Sp
  desc: Baseline board, trouble 8S'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8S'
  expect:
    plan_lines:
      - "push [8S'] onto HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4C 5H 6S 7H 8S']"

scenario baseline_board_9S
  desc: Baseline board, trouble 9S. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9S
  expect: no_plan

scenario baseline_board_9Sp
  desc: Baseline board, trouble 9S'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9S'
  expect: no_plan

scenario baseline_board_TS
  desc: Baseline board, trouble TS. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TS
  expect: no_plan

scenario baseline_board_TSp
  desc: Baseline board, trouble TS'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TS'
  expect: no_plan

scenario baseline_board_JS
  desc: Baseline board, trouble JS. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JS
  expect: no_plan

scenario baseline_board_JSp
  desc: Baseline board, trouble JS'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JS'
  expect: no_plan

scenario baseline_board_QS
  desc: Baseline board, trouble QS. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QS
  expect:
    plan_lines:
      - "push [QS] onto HELPER [KS AS 2S 3S] → [QS KS AS 2S 3S]"

scenario baseline_board_QSp
  desc: Baseline board, trouble QS'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QS'
  expect:
    plan_lines:
      - "push [QS'] onto HELPER [KS AS 2S 3S] → [QS' KS AS 2S 3S]"

scenario baseline_board_KSp
  desc: Baseline board, trouble KS'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): KS'
  expect: no_plan

scenario baseline_board_AHp
  desc: Baseline board, trouble AH'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): AH'
  expect:
    plan_lines:
      - "push [AH'] onto HELPER [2H 3H 4H] → [AH' 2H 3H 4H]"

scenario baseline_board_2Hp
  desc: Baseline board, trouble 2H'. 4-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 2H'
  expect:
    plan_lines:
      - "steal AC from HELPER [AC AD AH], absorb onto [2H'] → [AC 2H'] ; spawn [AD], [AH]"
      - "push [AD] onto HELPER [TD JD QD KD] → [TD JD QD KD AD]"
      - "push [AH] onto HELPER [2H 3H 4H] → [AH 2H 3H 4H]"
      - "peel 3S from HELPER [KS AS 2S 3S], absorb onto [AC 2H'] → [AC 2H' 3S] [→COMPLETE]"

scenario baseline_board_3Hp
  desc: Baseline board, trouble 3H'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 3H'
  expect: no_plan

scenario baseline_board_4Hp
  desc: Baseline board, trouble 4H'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 4H'
  expect: no_plan

scenario baseline_board_5Hp
  desc: Baseline board, trouble 5H'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 5H'
  expect:
    plan_lines:
      - "push [5H'] onto HELPER [2H 3H 4H] → [2H 3H 4H 5H']"

scenario baseline_board_6H
  desc: Baseline board, trouble 6H. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6H
  expect: no_plan

scenario baseline_board_6Hp
  desc: Baseline board, trouble 6H'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 6H'
  expect: no_plan

scenario baseline_board_7Hp
  desc: Baseline board, trouble 7H'. 1-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 7H'
  expect:
    plan_lines:
      - "push [7H'] onto HELPER [7S 7D 7C] → [7S 7D 7C 7H']"

scenario baseline_board_8H
  desc: Baseline board, trouble 8H. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8H
  expect: no_plan

scenario baseline_board_8Hp
  desc: Baseline board, trouble 8H'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 8H'
  expect: no_plan

scenario baseline_board_9H
  desc: Baseline board, trouble 9H. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9H
  expect: no_plan

scenario baseline_board_9Hp
  desc: Baseline board, trouble 9H'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): 9H'
  expect: no_plan

scenario baseline_board_TH
  desc: Baseline board, trouble TH. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TH
  expect: no_plan

scenario baseline_board_THp
  desc: Baseline board, trouble TH'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): TH'
  expect: no_plan

scenario baseline_board_JH
  desc: Baseline board, trouble JH. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JH
  expect: no_plan

scenario baseline_board_JHp
  desc: Baseline board, trouble JH'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): JH'
  expect: no_plan

scenario baseline_board_QH
  desc: Baseline board, trouble QH. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QH
  expect: no_plan

scenario baseline_board_QHp
  desc: Baseline board, trouble QH'. no plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): QH'
  expect: no_plan

scenario baseline_board_KH
  desc: Baseline board, trouble KH. 2-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): KH
  expect:
    plan_lines:
      - "peel KD from HELPER [TD JD QD KD], absorb onto [KH] → [KH KD]"
      - "peel KS from HELPER [KS AS 2S 3S], absorb onto [KH KD] → [KS KH KD] [→COMPLETE]"

scenario baseline_board_KHp
  desc: Baseline board, trouble KH'. 2-step plan. Auto-generated.
  op: solve
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H
  trouble:
    at (0,0): KH'
  expect:
    plan_lines:
      - "peel KD from HELPER [TD JD QD KD], absorb onto [KH'] → [KH' KD]"
      - "peel KS from HELPER [KS AS 2S 3S], absorb onto [KH' KD] → [KS KH' KD] [→COMPLETE]"
"""
