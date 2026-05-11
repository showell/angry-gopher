module Game.PuzzleFlagDslTest exposing (suite)

import Expect
import Game.PuzzleFlagDsl as PuzzleFlagDsl
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "PuzzleFlagDsl"
        [ test "happy path: session_id + board" <|
            \_ ->
                let
                    src =
                        "session_id: 17\n\nboard:\n  at ( 26,  26): 2♥ 3♥ 4♥\n  at (107,  52): 7♠ 7♦ 7♣"
                in
                PuzzleFlagDsl.parsePuzzleFlag src
                    |> Result.map (\f -> ( f.sessionId, List.length f.board ))
                    |> Expect.equal (Ok ( 17, 2 ))
        , test "tolerates extra scalar lines before board:" <|
            \_ ->
                let
                    src =
                        "session_id: 9\npuzzle_name: mined_002\n\nboard:\n  at (0, 0): A♥"
                in
                PuzzleFlagDsl.parsePuzzleFlag src
                    |> Result.map .sessionId
                    |> Expect.equal (Ok 9)
        , test "missing session_id is an error" <|
            \_ ->
                "board:\n  at (0, 0): A♥"
                    |> PuzzleFlagDsl.parsePuzzleFlag
                    |> Result.map (always ())
                    |> Expect.equal (Err "puzzle flag missing scalar: session_id")
        , test "non-integer session_id is an error" <|
            \_ ->
                "session_id: bogus\n\nboard:"
                    |> PuzzleFlagDsl.parsePuzzleFlag
                    |> Result.map (always ())
                    |> Expect.equal (Err "puzzle flag: session_id not an integer: bogus")
        ]
