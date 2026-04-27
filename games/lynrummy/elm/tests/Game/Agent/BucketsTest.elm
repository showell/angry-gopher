module Game.Agent.BucketsTest exposing (suite)

{-| Tests for `Game.Agent.Buckets` — pure helpers on the
four-bucket state. Mirrors `python/test_bfs_extract.py` for
the bucket helpers and the purity contracts.
-}

import Expect
import Game.Agent.Buckets as Buckets
import Game.Card exposing (Card, OriginDeck(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Card.cardFromLabel label DeckOne of
        Just c ->
            c

        Nothing ->
            -- A test-author bug, not a runtime branch.
            Debug.todo ("bad label: " ++ label)


suite : Test
suite =
    describe "Game.Agent.Buckets"
        [ test "empty state has zero trouble count" <|
            \_ ->
                Buckets.troubleCount Buckets.empty
                    |> Expect.equal 0
        , test "empty state is victorious (vacuously)" <|
            \_ ->
                Buckets.isVictory Buckets.empty
                    |> Expect.equal True
        , test "trouble count sums across trouble + growing" <|
            \_ ->
                let
                    state =
                        { helper = [ [ card "5H", card "6H", card "7H" ] ]
                        , trouble = [ [ card "AC" ], [ card "2D", card "3D" ] ]
                        , growing = [ [ card "JC", card "QC" ] ]
                        , complete = []
                        }
                in
                Buckets.troubleCount state
                    |> Expect.equal 5
        , test "non-victorious when trouble is non-empty" <|
            \_ ->
                let
                    state =
                        { helper = []
                        , trouble = [ [ card "AC" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                Buckets.isVictory state
                    |> Expect.equal False
        , test "non-victorious when a growing is shorter than 3" <|
            \_ ->
                let
                    state =
                        { helper = []
                        , trouble = []
                        , growing = [ [ card "AC", card "2D" ] ]
                        , complete = []
                        }
                in
                Buckets.isVictory state
                    |> Expect.equal False
        , test "victorious when trouble empty AND all growing length-3+" <|
            \_ ->
                let
                    state =
                        { helper = []
                        , trouble = []
                        , growing = [ [ card "5H", card "6H", card "7H" ] ]
                        , complete = []
                        }
                in
                Buckets.isVictory state
                    |> Expect.equal True
        ]
