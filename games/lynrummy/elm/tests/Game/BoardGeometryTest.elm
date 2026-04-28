module Game.BoardGeometryTest exposing (suite)

{-| Tests for `Game.BoardGeometry`. Ported from
`angry-cat/src/lyn_rummy/game/board_geometry_test.ts`.

All 15 source tests ported. No deferrals — this module has no
dependencies on protocol\_validation or PRNG.

-}

import Expect
import Game.BoardGeometry
    exposing
        ( BoardBounds
        , BoardGeometryStatus(..)
        , GeometryError
        , GeometryErrorKind(..)
        , classifyBoardGeometry
        , stackHeight
        , stackWidth
        , validateBoardGeometry
        )
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , CardStack
        )
import Test exposing (Test, describe, test)



-- HELPERS


bounds : BoardBounds
bounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


{-| Make a stack at `(left, top)` with `n` cards. Card values
don't matter for geometry — we just need the length.
-}
makeStack : Int -> Int -> Int -> CardStack
makeStack left top n =
    { boardCards = List.repeat n filler
    , loc = { top = top, left = left }
    }


filler : BoardCard
filler =
    { card = { value = Ace, suit = Club, originDeck = DeckOne }
    , state = FirmlyOnBoard
    }


anyErrorOfKind : GeometryErrorKind -> List GeometryError -> Bool
anyErrorOfKind kind errors =
    List.any (\e -> e.kind == kind) errors



-- SUITE


suite : Test
suite =
    describe "Game.BoardGeometry"
        [ validBoardsTests
        , outOfBoundsTests
        , overlapTests
        , classificationTests
        ]


validBoardsTests : Test
validBoardsTests =
    describe "valid boards"
        [ test "empty board has no errors" <|
            \_ ->
                Expect.equal [] (validateBoardGeometry [] bounds)
        , test "single stack within bounds is valid" <|
            \_ ->
                Expect.equal []
                    (validateBoardGeometry [ makeStack 10 10 3 ] bounds)
        , test "two non-overlapping stacks are valid" <|
            \_ ->
                let
                    stacks =
                        [ makeStack 10 10 3
                        , makeStack 10 100 4
                        ]
                in
                Expect.equal [] (validateBoardGeometry stacks bounds)
        , test "side-by-side stacks with margin are valid" <|
            \_ ->
                let
                    w =
                        stackWidth 3

                    stacks =
                        [ makeStack 10 10 3
                        , makeStack (10 + w + bounds.margin + 1) 10 3
                        ]
                in
                Expect.equal [] (validateBoardGeometry stacks bounds)
        ]


outOfBoundsTests : Test
outOfBoundsTests =
    describe "out of bounds"
        [ test "stack extends past the right edge" <|
            \_ ->
                let
                    errors =
                        validateBoardGeometry [ makeStack 780 10 3 ] bounds
                in
                Expect.all
                    [ List.length >> Expect.equal 1
                    , anyErrorOfKind OutOfBounds >> Expect.equal True
                    ]
                    errors
        , test "stack extends past the bottom edge" <|
            \_ ->
                let
                    errors =
                        validateBoardGeometry [ makeStack 10 570 3 ] bounds
                in
                Expect.all
                    [ List.length >> Expect.equal 1
                    , anyErrorOfKind OutOfBounds >> Expect.equal True
                    ]
                    errors
        , test "stack at negative x is out of bounds" <|
            \_ ->
                let
                    errors =
                        validateBoardGeometry [ makeStack -5 10 3 ] bounds
                in
                Expect.all
                    [ List.length >> Expect.equal 1
                    , anyErrorOfKind OutOfBounds >> Expect.equal True
                    ]
                    errors
        ]


overlapTests : Test
overlapTests =
    describe "overlap and proximity"
        [ test "identical positions overlap" <|
            \_ ->
                let
                    stacks =
                        [ makeStack 10 10 3, makeStack 10 10 3 ]
                in
                Expect.equal True
                    (anyErrorOfKind Overlap (validateBoardGeometry stacks bounds))
        , test "horizontally partial overlap" <|
            \_ ->
                let
                    stacks =
                        [ makeStack 10 10 5, makeStack 50 10 5 ]
                in
                Expect.equal True
                    (anyErrorOfKind Overlap (validateBoardGeometry stacks bounds))
        , test "stacks within margin are TooClose, not Overlap" <|
            \_ ->
                let
                    w =
                        stackWidth 3

                    stacks =
                        [ makeStack 10 10 3
                        , makeStack (10 + w + bounds.margin - 1) 10 3
                        ]

                    errors =
                        validateBoardGeometry stacks bounds
                in
                Expect.all
                    [ anyErrorOfKind TooClose >> Expect.equal True
                    , anyErrorOfKind Overlap >> Expect.equal False
                    ]
                    errors
        , test "three stacks, only the overlapping pair is reported" <|
            \_ ->
                let
                    stacks =
                        [ makeStack 10 10 3
                        , makeStack 10 100 3
                        , makeStack 10 10 3 -- overlaps with stack 0
                        ]

                    overlaps =
                        validateBoardGeometry stacks bounds
                            |> List.filter (\e -> e.kind == Overlap)
                in
                Expect.all
                    [ List.length >> Expect.equal 1
                    , List.head
                        >> Maybe.map .stackIndices
                        >> Expect.equal (Just [ 0, 2 ])
                    ]
                    overlaps
        ]


classificationTests : Test
classificationTests =
    describe "classifyBoardGeometry"
        [ test "cleanly spaced when there are no errors" <|
            \_ ->
                let
                    stacks =
                        [ makeStack 10 10 3, makeStack 10 100 3 ]
                in
                Expect.equal CleanlySpaced (classifyBoardGeometry stacks bounds)
        , test "crowded when only TooClose errors are present" <|
            \_ ->
                let
                    w =
                        stackWidth 3

                    stacks =
                        [ makeStack 10 10 3
                        , makeStack (10 + w + 1) 10 3 -- close but not overlapping
                        ]
                in
                Expect.equal Crowded (classifyBoardGeometry stacks bounds)
        , test "illegal on actual overlap" <|
            \_ ->
                let
                    stacks =
                        [ makeStack 10 10 3, makeStack 10 10 3 ]
                in
                Expect.equal Illegal (classifyBoardGeometry stacks bounds)
        , test "illegal on out-of-bounds" <|
            \_ ->
                Expect.equal Illegal
                    (classifyBoardGeometry [ makeStack 790 10 3 ] bounds)
        , test "stackHeight is a constant" <|
            \_ -> Expect.equal 40 stackHeight
        ]
