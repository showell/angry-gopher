module Lib.PuzzleFlagDslTest exposing (suite)

import Expect
import Lib.PuzzleFlagDsl as PuzzleFlagDsl
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "PuzzleFlagDsl"
        [ test "happy path: session_id + catalog with one puzzle" <|
            \_ ->
                let
                    src =
                        String.join "\n"
                            [ "session_id: 17"
                            , ""
                            , "catalog:"
                            , "  puzzle solo_demo"
                            , "    at ( 26,  26): 2♥ 3♥ 4♥"
                            , "    at (107,  52): 7♠ 7♦ 7♣"
                            ]
                in
                PuzzleFlagDsl.parsePuzzleFlag src
                    |> Result.map
                        (\f ->
                            ( f.sessionId
                            , List.map .name f.puzzles
                            , List.map (.board >> List.length) f.puzzles
                            )
                        )
                    |> Expect.equal (Ok ( 17, [ "solo_demo" ], [ 2 ] ))
        , test "multi-puzzle catalog preserves order" <|
            \_ ->
                let
                    src =
                        String.join "\n"
                            [ "session_id: 5"
                            , ""
                            , "catalog:"
                            , "  puzzle alpha"
                            , "    at (0, 0): A♥"
                            , "  puzzle beta"
                            , "    at (10, 10): K♠ Q♠"
                            , "    at (20, 20): J♣"
                            , "  puzzle gamma"
                            , "    at (30, 30): 7♦"
                            ]
                in
                PuzzleFlagDsl.parsePuzzleFlag src
                    |> Result.map
                        (\f ->
                            ( List.map .name f.puzzles
                            , List.map (.board >> List.length) f.puzzles
                            )
                        )
                    |> Expect.equal (Ok ( [ "alpha", "beta", "gamma" ], [ 1, 2, 1 ] ))
        , test "tolerates extra scalar lines before catalog:" <|
            \_ ->
                let
                    src =
                        String.join "\n"
                            [ "session_id: 9"
                            , "created_at: 1779039778"
                            , ""
                            , "catalog:"
                            , "  puzzle only"
                            , "    at (0, 0): A♥"
                            ]
                in
                PuzzleFlagDsl.parsePuzzleFlag src
                    |> Result.map .sessionId
                    |> Expect.equal (Ok 9)
        , test "missing session_id is an error" <|
            \_ ->
                "catalog:\n  puzzle x\n    at (0, 0): A♥"
                    |> PuzzleFlagDsl.parsePuzzleFlag
                    |> Result.map (always ())
                    |> Expect.equal (Err "puzzle flag missing scalar: session_id")
        , test "non-integer session_id is an error" <|
            \_ ->
                "session_id: bogus\n\ncatalog:"
                    |> PuzzleFlagDsl.parsePuzzleFlag
                    |> Result.map (always ())
                    |> Expect.equal (Err "puzzle flag: session_id not an integer: bogus")
        ]
