module LynRummy.PlayerTurnTest exposing (suite)

{-| Tests for `LynRummy.PlayerTurn`. Ported from
`angry-cat/src/lyn_rummy/game/player_turn_test.ts`.
-}

import Expect
import LynRummy.PlayerTurn as PT
    exposing
        ( CompleteTurnResult(..)
        , PlayerTurn
        )
import LynRummy.Score as Score
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "LynRummy.PlayerTurn"
        [ playAndUndoTests
        , boardDeltaTests
        , cardsPlayedBonusTests
        , emptyHandBonusTests
        , victoryBonusTests
        , turnResultTests
        , victoryTurnResultTests
        ]


playAndUndoTests : Test
playAndUndoTests =
    describe "play a card then undo"
        [ test "cards played goes 0 -> 1 -> 0; final score is 0 at board=starting" <|
            \_ ->
                let
                    t1 =
                        PT.new 100 |> PT.updateScoreAfterMove

                    t2 =
                        t1 |> PT.undoScoreAfterMove
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (PT.getNumCardsPlayed t1)
                    , \_ -> Expect.equal 0 (PT.getNumCardsPlayed t2)
                    , \_ -> Expect.equal 0 (PT.getScore 100 t2)
                    ]
                    ()
        ]


boardDeltaTests : Test
boardDeltaTests =
    describe "board delta with no cards played"
        [ test "+50 board delta -> score 50" <|
            \_ -> Expect.equal 50 (PT.getScore 150 (PT.new 100))
        , test "same board -> score 0" <|
            \_ -> Expect.equal 0 (PT.getScore 100 (PT.new 100))
        , test "-20 board delta -> score -20" <|
            \_ -> Expect.equal -20 (PT.getScore 80 (PT.new 100))
        ]


cardsPlayedBonusTests : Test
cardsPlayedBonusTests =
    describe "cards played bonus matches Score.forCardsPlayed"
        [ test "1 card -> score = forCardsPlayed 1 = 300" <|
            \_ ->
                let
                    t =
                        PT.new 0 |> PT.updateScoreAfterMove
                in
                Expect.equal (Score.forCardsPlayed 1) (PT.getScore 0 t)
        , test "2 cards -> score = forCardsPlayed 2 = 600" <|
            \_ ->
                let
                    t =
                        PT.new 0
                            |> PT.updateScoreAfterMove
                            |> PT.updateScoreAfterMove
                in
                Expect.equal (Score.forCardsPlayed 2) (PT.getScore 0 t)
        ]


emptyHandBonusTests : Test
emptyHandBonusTests =
    describe "empty-hand bonus: +1000, revokable"
        [ test "one card + empty-hand (non-victor) -> score = forCardsPlayed 1 + 1000" <|
            \_ ->
                let
                    t =
                        PT.new 0
                            |> PT.updateScoreAfterMove
                            |> PT.updateScoreForEmptyHand False
                in
                Expect.all
                    [ \_ -> Expect.equal True (PT.emptiedHand t)
                    , \_ -> Expect.equal (Score.forCardsPlayed 1 + 1000) (PT.getScore 0 t)
                    ]
                    ()
        , test "revokeEmptyHandBonuses restores non-bonus state" <|
            \_ ->
                let
                    t =
                        PT.new 0
                            |> PT.updateScoreAfterMove
                            |> PT.updateScoreForEmptyHand False
                            |> PT.revokeEmptyHandBonuses
                in
                Expect.all
                    [ \_ -> Expect.equal False (PT.emptiedHand t)
                    , \_ -> Expect.equal (Score.forCardsPlayed 1) (PT.getScore 0 t)
                    ]
                    ()
        ]


victoryBonusTests : Test
victoryBonusTests =
    describe "victory bonus: +500 on top of empty-hand"
        [ test "one card + empty-hand (victor) -> score = forCardsPlayed 1 + 1000 + 500" <|
            \_ ->
                let
                    t =
                        PT.new 0
                            |> PT.updateScoreAfterMove
                            |> PT.updateScoreForEmptyHand True
                in
                Expect.all
                    [ \_ -> Expect.equal True (PT.gotVictoryBonus t)
                    , \_ -> Expect.equal (Score.forCardsPlayed 1 + 1000 + 500) (PT.getScore 0 t)
                    ]
                    ()
        ]


turnResultTests : Test
turnResultTests =
    describe "turnResult discriminator"
        [ test "no cards played -> SuccessButNeedsCards" <|
            \_ ->
                Expect.equal SuccessButNeedsCards (PT.turnResult (PT.new 0))
        , test "cards played -> Success" <|
            \_ ->
                let
                    t =
                        PT.new 0 |> PT.updateScoreAfterMove
                in
                Expect.equal Success (PT.turnResult t)
        , test "empty hand (non-victor) -> SuccessWithHandEmptied" <|
            \_ ->
                let
                    t =
                        PT.new 0
                            |> PT.updateScoreAfterMove
                            |> PT.updateScoreForEmptyHand False
                in
                Expect.equal SuccessWithHandEmptied (PT.turnResult t)
        ]


victoryTurnResultTests : Test
victoryTurnResultTests =
    describe "turnResult with victory -> SuccessAsVictor"
        [ test "empty-hand victor -> SuccessAsVictor" <|
            \_ ->
                let
                    t =
                        PT.new 0
                            |> PT.updateScoreAfterMove
                            |> PT.updateScoreForEmptyHand True
                in
                Expect.equal SuccessAsVictor (PT.turnResult t)
        ]
