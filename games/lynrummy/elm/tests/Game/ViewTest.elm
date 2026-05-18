module Game.ViewTest exposing (suite)

{-| Tests for `statusForCompleteTurn` — keeps every
CompleteTurnResult branch (including Failure, which was dead
code before LEAN_PASS) wired to its status kind.
-}

import Expect
import Lib.CompleteTurn exposing (CompleteTurnOutcome, statusForCompleteTurn)
import Lib.PlayerTurn exposing (CompleteTurnResult(..))
import Lib.Status exposing (StatusKind(..))
import Test exposing (Test, describe, test)


outcome : CompleteTurnResult -> CompleteTurnOutcome
outcome result =
    { result = result, cardsDrawn = 0, dealtCards = [] }


suite : Test
suite =
    statusTests


statusTests : Test
statusTests =
    describe "statusForCompleteTurn"
        [ test "Failure → Scold" <|
            \_ ->
                statusForCompleteTurn (Ok (outcome Failure))
                    |> .kind
                    |> Expect.equal Scold
        , test "Success → Celebrate" <|
            \_ ->
                statusForCompleteTurn (Ok (outcome Success))
                    |> .kind
                    |> Expect.equal Celebrate
        , test "SuccessButNeedsCards → Inform" <|
            \_ ->
                statusForCompleteTurn (Ok (outcome SuccessButNeedsCards))
                    |> .kind
                    |> Expect.equal Inform
        , test "SuccessAsVictor → Celebrate" <|
            \_ ->
                statusForCompleteTurn (Ok (outcome SuccessAsVictor))
                    |> .kind
                    |> Expect.equal Celebrate
        , test "SuccessWithHandEmptied → Celebrate" <|
            \_ ->
                statusForCompleteTurn (Ok (outcome SuccessWithHandEmptied))
                    |> .kind
                    |> Expect.equal Celebrate
        , test "Err → Scold (server unreachable)" <|
            \_ ->
                statusForCompleteTurn (Err ())
                    |> .kind
                    |> Expect.equal Scold
        ]


