module Main.ViewTest exposing (suite)

{-| Tests for the turn-ceremony helpers in Main.View:
`statusForCompleteTurn` and `popupForCompleteTurn`.

These are the functions that translate a CompleteTurnOutcome into
the status bar message and popup the player sees. Each
CompleteTurnResult branch gets a test, plus the Err path (server
unreachable). Before LEAN_PASS the Failure branch was dead code —
this suite exists to keep it alive.
-}

import Expect
import Game.Game exposing (CompleteTurnOutcome)
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Main.State exposing (StatusKind(..))
import Main.View exposing (popupForCompleteTurn, statusForCompleteTurn)
import Test exposing (Test, describe, test)


outcome : CompleteTurnResult -> CompleteTurnOutcome
outcome result =
    { result = result, turnScore = 0, cardsDrawn = 0, dealtCards = [] }


suite : Test
suite =
    describe "Main.View turn-ceremony helpers"
        [ statusTests
        , popupTests
        ]


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


popupTests : Test
popupTests =
    describe "popupForCompleteTurn"
        [ test "Failure → Angry Cat scolds dirty board" <|
            \_ ->
                popupForCompleteTurn (Ok (outcome Failure))
                    |> Maybe.map .admin
                    |> Expect.equal (Just "Angry Cat")
        , test "SuccessButNeedsCards → Oliver sympathizes" <|
            \_ ->
                popupForCompleteTurn (Ok (outcome SuccessButNeedsCards))
                    |> Maybe.map .admin
                    |> Expect.equal (Just "Oliver")
        , test "Success → Steve celebrates" <|
            \_ ->
                popupForCompleteTurn (Ok (outcome Success))
                    |> Maybe.map .admin
                    |> Expect.equal (Just "Steve")
        , test "SuccessAsVictor → Steve celebrates" <|
            \_ ->
                popupForCompleteTurn (Ok (outcome SuccessAsVictor))
                    |> Maybe.map .admin
                    |> Expect.equal (Just "Steve")
        , test "SuccessWithHandEmptied → Steve celebrates" <|
            \_ ->
                popupForCompleteTurn (Ok (outcome SuccessWithHandEmptied))
                    |> Maybe.map .admin
                    |> Expect.equal (Just "Steve")
        , test "Err → Angry Cat (server unreachable)" <|
            \_ ->
                popupForCompleteTurn (Err ())
                    |> Maybe.map .admin
                    |> Expect.equal (Just "Angry Cat")
        ]
