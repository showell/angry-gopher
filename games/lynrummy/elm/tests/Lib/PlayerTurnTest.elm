module Lib.PlayerTurnTest exposing (suite)

{-| Tests for `Lib.PlayerTurn`. Slimmed-down after the
scoring system was retired — what remains exercises the
turn-result discriminator (cards-played → empty-hand →
victor) and the play-then-undo card counter.
-}

import Expect
import Lib.PlayerTurn as PT
    exposing
        ( CompleteTurnResult(..)
        )
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Lib.PlayerTurn"
        [ playAndUndoTests
        , emptyHandFlagTests
        , turnResultTests
        , victoryTurnResultTests
        ]


playAndUndoTests : Test
playAndUndoTests =
    describe "play a card then undo"
        [ test "cards played goes 0 -> 1 -> 0" <|
            \_ ->
                let
                    t1 =
                        PT.new |> PT.noteCardPlayed

                    t2 =
                        t1 |> PT.undoCardPlayed
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (PT.getNumCardsPlayed t1)
                    , \_ -> Expect.equal 0 (PT.getNumCardsPlayed t2)
                    ]
                    ()
        ]


emptyHandFlagTests : Test
emptyHandFlagTests =
    describe "empty-hand flag is settable and revokable"
        [ test "noteEmptyHand False sets handEmptied, leaves victoryGained False" <|
            \_ ->
                let
                    t =
                        PT.new
                            |> PT.noteCardPlayed
                            |> PT.noteEmptyHand False
                in
                Expect.all
                    [ \_ -> Expect.equal True (PT.wasHandEmptied t)
                    , \_ -> Expect.equal False (PT.wasVictoryBonusGained t)
                    ]
                    ()
        , test "noteEmptyHand True sets both flags" <|
            \_ ->
                let
                    t =
                        PT.new
                            |> PT.noteCardPlayed
                            |> PT.noteEmptyHand True
                in
                Expect.all
                    [ \_ -> Expect.equal True (PT.wasHandEmptied t)
                    , \_ -> Expect.equal True (PT.wasVictoryBonusGained t)
                    ]
                    ()
        , test "revokeEmptyHandBonuses clears both flags" <|
            \_ ->
                let
                    t =
                        PT.new
                            |> PT.noteCardPlayed
                            |> PT.noteEmptyHand True
                            |> PT.revokeEmptyHandBonuses
                in
                Expect.all
                    [ \_ -> Expect.equal False (PT.wasHandEmptied t)
                    , \_ -> Expect.equal False (PT.wasVictoryBonusGained t)
                    ]
                    ()
        ]


turnResultTests : Test
turnResultTests =
    describe "turnResult discriminator"
        [ test "no cards played -> SuccessButNeedsCards" <|
            \_ ->
                Expect.equal SuccessButNeedsCards (PT.turnResult PT.new)
        , test "cards played -> Success" <|
            \_ ->
                let
                    t =
                        PT.new |> PT.noteCardPlayed
                in
                Expect.equal Success (PT.turnResult t)
        , test "empty hand (non-victor) -> SuccessWithHandEmptied" <|
            \_ ->
                let
                    t =
                        PT.new
                            |> PT.noteCardPlayed
                            |> PT.noteEmptyHand False
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
                        PT.new
                            |> PT.noteCardPlayed
                            |> PT.noteEmptyHand True
                in
                Expect.equal SuccessAsVictor (PT.turnResult t)
        ]
