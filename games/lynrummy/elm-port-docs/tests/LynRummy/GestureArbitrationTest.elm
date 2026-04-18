module LynRummy.GestureArbitrationTest exposing (suite)

{-| Tests for `LynRummy.GestureArbitration`. Pure helpers
for click-vs-drag arbitration during a board interaction.

The native event flow itself (mousedown / mousemove /
mouseup, subscriptions, view wiring) lives in `Main.elm` and
isn't reachable from elm-test. Everything that *can* be made
pure has been pulled out into the module under test here.

-}

import Expect
import LynRummy.Card exposing (OriginDeck(..))
import LynRummy.CardStack as CardStack exposing (CardStack)
import LynRummy.GestureArbitration as GA
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "GestureArbitration"
        [ describe "distSquared"
            [ test "equal points → 0" <|
                \_ ->
                    GA.distSquared { x = 5, y = 7 } { x = 5, y = 7 }
                        |> Expect.equal 0
            , test "(0,0) to (3,4) → 25" <|
                \_ ->
                    GA.distSquared { x = 0, y = 0 } { x = 3, y = 4 }
                        |> Expect.equal 25
            , test "(0,0) to (1,0) → 1 (boundary value)" <|
                \_ ->
                    GA.distSquared { x = 0, y = 0 } { x = 1, y = 0 }
                        |> Expect.equal 1
            , test "(0,0) to (1,1) → 2 (just past boundary)" <|
                \_ ->
                    GA.distSquared { x = 0, y = 0 } { x = 1, y = 1 }
                        |> Expect.equal 2
            , test "negative deltas square positively" <|
                \_ ->
                    GA.distSquared { x = 10, y = 10 } { x = 0, y = 0 }
                        |> Expect.equal 200
            ]
        , describe "clickIntentAfterMove"
            [ test "Nothing in → Nothing out (zero distance)" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 0, y = 0 } { x = 0, y = 0 } Nothing
                        |> Expect.equal Nothing
            , test "Nothing in → Nothing out (large distance)" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 0, y = 0 } { x = 100, y = 100 } Nothing
                        |> Expect.equal Nothing
            , test "Just survives zero movement" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 5, y = 5 } { x = 5, y = 5 } (Just 2)
                        |> Expect.equal (Just 2)
            , test "Just survives 1-pixel axis-aligned movement (distSquared=1, NOT > threshold)" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 0, y = 0 } { x = 1, y = 0 } (Just 2)
                        |> Expect.equal (Just 2)
            , test "Just dies at diagonal (1,1) movement (distSquared=2 > threshold 1)" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 0, y = 0 } { x = 1, y = 1 } (Just 2)
                        |> Expect.equal Nothing
            , test "Just dies at axis-aligned 2-pixel movement (distSquared=4)" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 0, y = 0 } { x = 2, y = 0 } (Just 2)
                        |> Expect.equal Nothing
            , test "Just dies at large movement" <|
                \_ ->
                    GA.clickIntentAfterMove { x = 0, y = 0 } { x = 50, y = 50 } (Just 2)
                        |> Expect.equal Nothing
            , test "death is permanent within a gesture (subsequent calls keep it Nothing)" <|
                \_ ->
                    let
                        afterMove =
                            GA.clickIntentAfterMove { x = 0, y = 0 } { x = 50, y = 50 } (Just 2)

                        afterReturnToOrigin =
                            GA.clickIntentAfterMove { x = 0, y = 0 } { x = 0, y = 0 } afterMove
                    in
                    afterReturnToOrigin
                        |> Expect.equal Nothing
            ]
        , describe "applySplit"
            [ test "splitting a 3-card stack at index 1 yields 2 stacks total" <|
                \_ ->
                    let
                        stack3 =
                            makeStack "AS,2S,3S"
                    in
                    GA.applySplit 0 1 [ stack3 ]
                        |> List.length
                        |> Expect.equal 2
            , test "split removes the original stack from the board" <|
                \_ ->
                    let
                        stack3 =
                            makeStack "AS,2S,3S"

                        result =
                            GA.applySplit 0 1 [ stack3 ]
                    in
                    List.any (CardStack.stacksEqual stack3) result
                        |> Expect.equal False
            , test "split preserves other stacks on the board" <|
                \_ ->
                    let
                        target =
                            makeStack "AS,2S,3S"

                        keeper =
                            makeStackAt "TD,JD,QD" 60 0

                        result =
                            GA.applySplit 1 1 [ keeper, target ]
                    in
                    List.any (CardStack.stacksEqual keeper) result
                        |> Expect.equal True
            , test "splitting at index 0 of a 3-card stack still yields 2 stacks" <|
                \_ ->
                    let
                        stack3 =
                            makeStack "AS,2S,3S"
                    in
                    GA.applySplit 0 0 [ stack3 ]
                        |> List.length
                        |> Expect.equal 2
            , test "splitting at index 2 of a 3-card stack still yields 2 stacks" <|
                \_ ->
                    let
                        stack3 =
                            makeStack "AS,2S,3S"
                    in
                    GA.applySplit 0 2 [ stack3 ]
                        |> List.length
                        |> Expect.equal 2
            , test "splitting a 1-card stack is a no-op (size unchanged, stack preserved)" <|
                \_ ->
                    let
                        stack1 =
                            makeStack "AS"

                        result =
                            GA.applySplit 0 0 [ stack1 ]
                    in
                    Expect.all
                        [ \r -> List.length r |> Expect.equal 1
                        , \r -> List.any (CardStack.stacksEqual stack1) r |> Expect.equal True
                        ]
                        result
            , test "out-of-bounds stack index leaves the board unchanged" <|
                \_ ->
                    let
                        stack3 =
                            makeStack "AS,2S,3S"

                        board =
                            [ stack3 ]
                    in
                    GA.applySplit 5 1 board
                        |> Expect.equal board
            , test "splitting on an empty board is a no-op" <|
                \_ ->
                    GA.applySplit 0 0 []
                        |> Expect.equal []
            ]
        ]



-- HELPERS


makeStack : String -> CardStack
makeStack shorthand =
    makeStackAt shorthand 0 0


makeStackAt : String -> Int -> Int -> CardStack
makeStackAt shorthand top left =
    CardStack.fromShorthand shorthand DeckOne { top = top, left = left }
        |> Maybe.withDefault { boardCards = [], loc = { top = top, left = left } }
