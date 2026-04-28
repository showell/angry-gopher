module Game.ScoreTest exposing (suite)

{-| Tests for `Game.Score`. Ported from
`angry-cat/src/lyn_rummy/core/score_test.ts`.
-}

import Expect
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardFromLabel)
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , BoardLocation
        , CardStack
        )
import Game.Score
    exposing
        ( forCardsPlayed
        , forStack
        , forStacks
        , stackTypeValue
        )
import Game.Rules.StackType exposing (CardStackType(..))
import Test exposing (Test, describe, test)



-- HELPERS


origin : BoardLocation
origin =
    { top = 0, left = 0 }


fallback : Card
fallback =
    { value = Ace, suit = Club, originDeck = DeckOne }


card : String -> OriginDeck -> Card
card label deck =
    cardFromLabel label deck |> Maybe.withDefault fallback


stackFrom : List String -> CardStack
stackFrom labels =
    { boardCards =
        List.map
            (\l -> { card = card l DeckOne, state = FirmlyOnBoard })
            labels
    , loc = origin
    }



-- SUITE


suite : Test
suite =
    describe "Game.Score"
        [ stackTypeValueTests
        , forStackTests
        , forStacksTests
        , splitsAreFreeTests
        , forCardsPlayedTests
        , runsVsSetsTests
        ]


stackTypeValueTests : Test
stackTypeValueTests =
    describe "stackTypeValue"
        [ test "PureRun -> 100" <|
            \_ -> Expect.equal 100 (stackTypeValue PureRun)
        , test "Set -> 60" <|
            \_ -> Expect.equal 60 (stackTypeValue Set)
        , test "RedBlackRun -> 50" <|
            \_ -> Expect.equal 50 (stackTypeValue RedBlackRun)
        , test "Incomplete -> 0" <|
            \_ -> Expect.equal 0 (stackTypeValue Incomplete)
        , test "Bogus -> 0" <|
            \_ -> Expect.equal 0 (stackTypeValue Bogus)
        , test "Dup -> 0" <|
            \_ -> Expect.equal 0 (stackTypeValue Dup)
        ]


forStackTests : Test
forStackTests =
    describe "forStack: size * stackTypeValue"
        [ test "3-card pure run AH 2H 3H -> 300" <|
            \_ -> Expect.equal 300 (forStack (stackFrom [ "AH", "2H", "3H" ]))
        , test "4-card pure run AH 2H 3H 4H -> 400" <|
            \_ -> Expect.equal 400 (forStack (stackFrom [ "AH", "2H", "3H", "4H" ]))
        , test "3-card set 7S 7D 7C -> 180" <|
            \_ -> Expect.equal 180 (forStack (stackFrom [ "7S", "7D", "7C" ]))
        , test "3-card red/black run AH 2S 3H -> 150" <|
            \_ -> Expect.equal 150 (forStack (stackFrom [ "AH", "2S", "3H" ]))
        , test "2-card incomplete -> 0 (Incomplete has 0 type value)" <|
            \_ -> Expect.equal 0 (forStack (stackFrom [ "AH", "2H" ]))
        ]


forStacksTests : Test
forStacksTests =
    describe "forStacks: sum of forStack"
        [ test "three stacks: 300 + 180 + 150 = 630" <|
            \_ ->
                Expect.equal 630
                    (forStacks
                        [ stackFrom [ "AH", "2H", "3H" ]
                        , stackFrom [ "7S", "7D", "7C" ]
                        , stackFrom [ "AH", "2S", "3H" ]
                        ]
                    )
        , test "empty list -> 0" <|
            \_ -> Expect.equal 0 (forStacks [])
        ]


splitsAreFreeTests : Test
splitsAreFreeTests =
    describe "splits are free under the flat formula"
        [ test "6-pure-run scores 600; same cards split into two 3-pure-runs also score 600" <|
            \_ ->
                let
                    longRun =
                        forStack (stackFrom [ "AH", "2H", "3H", "4H", "5H", "6H" ])

                    split =
                        forStacks
                            [ stackFrom [ "AH", "2H", "3H" ]
                            , stackFrom [ "4H", "5H", "6H" ]
                            ]
                in
                Expect.all
                    [ \_ -> Expect.equal 600 longRun
                    , \_ -> Expect.equal 600 split
                    ]
                    ()
        ]


forCardsPlayedTests : Test
forCardsPlayedTests =
    describe "forCardsPlayed: 200 + 100*n*n for n > 0"
        [ test "-1 -> 0" <|
            \_ -> Expect.equal 0 (forCardsPlayed -1)
        , test "0 -> 0" <|
            \_ -> Expect.equal 0 (forCardsPlayed 0)
        , test "1 -> 300 (200 + 100*1*1)" <|
            \_ -> Expect.equal 300 (forCardsPlayed 1)
        , test "2 -> 600 (200 + 100*2*2)" <|
            \_ -> Expect.equal 600 (forCardsPlayed 2)
        , test "3 -> 1100 (200 + 100*3*3)" <|
            \_ -> Expect.equal 1100 (forCardsPlayed 3)
        ]


runsVsSetsTests : Test
runsVsSetsTests =
    describe "same 9 cards: pure runs outscore sets"
        [ test "runs score 900; sets score 540" <|
            \_ ->
                let
                    runsScore =
                        forStacks
                            [ stackFrom [ "AH", "2H", "3H" ]
                            , stackFrom [ "AS", "2S", "3S" ]
                            , stackFrom [ "AD", "2D", "3D" ]
                            ]

                    setsScore =
                        forStacks
                            [ stackFrom [ "AH", "AS", "AD" ]
                            , stackFrom [ "2H", "2S", "2D" ]
                            , stackFrom [ "3H", "3S", "3D" ]
                            ]
                in
                Expect.all
                    [ \_ -> Expect.equal 900 runsScore
                    , \_ -> Expect.equal 540 setsScore
                    , \_ ->
                        if runsScore > setsScore then
                            Expect.pass

                        else
                            Expect.fail "pure runs should outscore sets"
                    ]
                    ()
        ]
