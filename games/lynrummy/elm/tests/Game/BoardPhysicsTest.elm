module Game.BoardPhysicsTest exposing (suite)

{-| Tests for `Game.BoardPhysics`. No direct TS test
(`core/board_physics.ts` has no \*\_test.ts companion); the
functions are indirectly exercised by the trick tests.

This file adds the direct coverage the TS port was missing.
Current-Claude filling in a thin spot per the porting cheat
sheet: "If the source has no tests, that itself is the
finding."

-}

import Expect
import Game.BoardPhysics exposing (canExtract, joinAdjacentRuns)
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardFromLabel)
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , BoardLocation
        , CardStack
        )
import Test exposing (Test, describe, test)



-- HELPERS


origin : BoardLocation
origin =
    { top = 0, left = 0 }


at : Int -> Int -> BoardLocation
at top left =
    { top = top, left = left }


fallback : Card
fallback =
    { value = Ace, suit = Club, originDeck = DeckOne }


card : String -> OriginDeck -> Card
card label deck =
    cardFromLabel label deck |> Maybe.withDefault fallback


stackAt : BoardLocation -> List String -> CardStack
stackAt loc labels =
    { boardCards =
        List.map
            (\l -> { card = card l DeckOne, state = FirmlyOnBoard })
            labels
    , loc = loc
    }


stackOf : List String -> CardStack
stackOf =
    stackAt origin



-- SUITE


suite : Test
suite =
    describe "Game.BoardPhysics"
        [ canExtractTests
        , joinAdjacentRunsTests
        ]


canExtractTests : Test
canExtractTests =
    describe "canExtract"
        [ test "3-card pure run: no card is extractable (would break the run)" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2H", "3H" ]
                in
                Expect.all
                    [ \_ -> Expect.equal False (canExtract s 0)
                    , \_ -> Expect.equal False (canExtract s 1)
                    , \_ -> Expect.equal False (canExtract s 2)
                    ]
                    ()
        , test "4-card pure run: end peels OK, middle not" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2H", "3H", "4H" ]
                in
                Expect.all
                    [ \_ -> Expect.equal True (canExtract s 0)
                    , \_ -> Expect.equal False (canExtract s 1)
                    , \_ -> Expect.equal False (canExtract s 2)
                    , \_ -> Expect.equal True (canExtract s 3)
                    ]
                    ()
        , test "7-card pure run: end peels OK; middle peel at index 3 OK (splits 3+3)" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2H", "3H", "4H", "5H", "6H", "7H" ]
                in
                Expect.all
                    [ \_ -> Expect.equal True (canExtract s 0)
                    , \_ -> Expect.equal False (canExtract s 1)
                    , \_ -> Expect.equal False (canExtract s 2)
                    , \_ -> Expect.equal True (canExtract s 3)
                    , \_ -> Expect.equal False (canExtract s 4)
                    , \_ -> Expect.equal False (canExtract s 5)
                    , \_ -> Expect.equal True (canExtract s 6)
                    ]
                    ()
        , test "3-card set: no card is extractable" <|
            \_ ->
                let
                    s =
                        stackOf [ "7S", "7D", "7C" ]
                in
                Expect.all
                    [ \_ -> Expect.equal False (canExtract s 0)
                    , \_ -> Expect.equal False (canExtract s 1)
                    , \_ -> Expect.equal False (canExtract s 2)
                    ]
                    ()
        , test "4-card set: any card is extractable" <|
            \_ ->
                let
                    s =
                        stackOf [ "7S", "7D", "7C", "7H" ]
                in
                Expect.all
                    [ \_ -> Expect.equal True (canExtract s 0)
                    , \_ -> Expect.equal True (canExtract s 1)
                    , \_ -> Expect.equal True (canExtract s 2)
                    , \_ -> Expect.equal True (canExtract s 3)
                    ]
                    ()
        , test "3-card red/black run: NOT extractable (size < 4)" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2S", "3H" ]
                in
                Expect.equal False (canExtract s 0)
        , test "4-card red/black run: end peels OK" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2S", "3H", "4S" ]
                in
                Expect.all
                    [ \_ -> Expect.equal True (canExtract s 0)
                    , \_ -> Expect.equal False (canExtract s 1)
                    , \_ -> Expect.equal False (canExtract s 2)
                    , \_ -> Expect.equal True (canExtract s 3)
                    ]
                    ()
        , test "2-card incomplete: nothing extractable" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2H" ]
                in
                Expect.equal False (canExtract s 0)
        ]


joinAdjacentRunsTests : Test
joinAdjacentRunsTests =
    describe "joinAdjacentRuns"
        [ test "empty board: unchanged" <|
            \_ ->
                let
                    result =
                        joinAdjacentRuns []
                in
                Expect.all
                    [ \_ -> Expect.equal [] result.board
                    , \_ -> Expect.equal False result.changed
                    ]
                    ()
        , test "single run: unchanged (nothing to merge with)" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2H", "3H" ]

                    result =
                        joinAdjacentRuns [ s ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (List.length result.board)
                    , \_ -> Expect.equal False result.changed
                    ]
                    ()
        , test "two mergeable 3-runs: collapse into one 6-run, changed=True" <|
            \_ ->
                let
                    a =
                        stackAt (at 0 0) [ "AH", "2H", "3H" ]

                    b =
                        stackAt (at 0 200) [ "4H", "5H", "6H" ]

                    result =
                        joinAdjacentRuns [ a, b ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (List.length result.board)
                    , \_ -> Expect.equal True result.changed
                    , \_ ->
                        case result.board of
                            [ merged ] ->
                                Expect.equal 6 (List.length merged.boardCards)

                            _ ->
                                Expect.fail "expected single merged stack"
                    ]
                    ()
        , test "three stacks where two merge, one stands alone" <|
            \_ ->
                let
                    a =
                        stackAt (at 0 0) [ "AH", "2H", "3H" ]

                    b =
                        stackAt (at 0 200) [ "4H", "5H", "6H" ]

                    c =
                        stackAt (at 100 0) [ "7S", "7D", "7C" ]

                    result =
                        joinAdjacentRuns [ a, b, c ]
                in
                Expect.all
                    [ \_ -> Expect.equal 2 (List.length result.board)
                    , \_ -> Expect.equal True result.changed
                    ]
                    ()
        , test "non-mergeable pair: unchanged" <|
            \_ ->
                let
                    a =
                        stackAt (at 0 0) [ "AH", "2H", "3H" ]

                    b =
                        stackAt (at 0 200) [ "7S", "7D", "7C" ]

                    result =
                        joinAdjacentRuns [ a, b ]
                in
                Expect.all
                    [ \_ -> Expect.equal 2 (List.length result.board)
                    , \_ -> Expect.equal False result.changed
                    ]
                    ()
        ]
