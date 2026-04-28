module Game.Agent.BfsTest exposing (suite)

{-| Tests for `Game.Agent.Bfs.solve` — the BFS planner. Small
hand-built puzzles with known plan lengths verify the
iterative-cap loop terminates correctly and returns the
shortest plan respecting the cap.
-}

import Expect
import Game.Agent.Bfs as Bfs
import Game.Rules.Card exposing (Card, OriginDeck(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Rules.Card.cardFromLabel label DeckOne of
        Just c ->
            c

        Nothing ->
            Debug.todo ("bad label: " ++ label)


suite : Test
suite =
    describe "Game.Agent.Bfs.solve"
        [ test "empty state is solved in zero moves" <|
            \_ ->
                Bfs.solve
                    { helper = []
                    , trouble = []
                    , growing = []
                    , complete = []
                    }
                    |> Maybe.map List.length
                    |> Expect.equal (Just 0)
        , test "1-line free pull: trouble singleton onto growing 2-partial" <|
            \_ ->
                let
                    state =
                        { helper = []
                        , trouble = [ [ card "4H" ] ]
                        , growing = [ [ card "5H", card "6H" ] ]
                        , complete = []
                        }
                in
                Bfs.solve state
                    |> Maybe.map List.length
                    |> Expect.equal (Just 1)
        , test "1-line peel: trouble singleton extends a length-4 helper run" <|
            \_ ->
                let
                    state =
                        { helper = [ [ card "5H", card "6H", card "7H", card "8H" ] ]
                        , trouble = [ [ card "4H" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                Bfs.solve state
                    |> Maybe.map List.length
                    |> Expect.equal (Just 1)
        , test "1-line engulf: GROWING [AC 2D] + HELPER [3S 4D 5C]" <|
            \_ ->
                let
                    state =
                        { helper = [ [ card "3S", card "4D", card "5C" ] ]
                        , trouble = []
                        , growing = [ [ card "AC", card "2D" ] ]
                        , complete = []
                        }
                in
                Bfs.solve state
                    |> Maybe.map List.length
                    |> Expect.equal (Just 1)
        , test "unsolvable returns Nothing within outer cap" <|
            \_ ->
                let
                    -- A trouble card with no neighbors at all on
                    -- the board — nothing can absorb it.
                    state =
                        { helper = []
                        , trouble = [ [ card "AC" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                Bfs.solveWithCap 3 state
                    |> Expect.equal Nothing
        ]
