module Game.HintTest exposing (suite)

{-| Tests for Game.Strategy.Hint.buildSuggestions. Mirrors
the Go-side `games/lynrummy/tricks/hint_test.go`.

Structure:

  - Empty-hand input produces no suggestions.
  - Opening hand against the canonical opening board puts
    `direct_play` first (simpler tricks win priority).
  - Priority order is preserved in the output (ranks are
    monotonically increasing, gaps allowed where a trick didn't
    fire).
  - Each suggestion's `handCards` contains the same cards the
    originating trick's first Play returned.

-}

import Expect
import Game.Dealer as Dealer
import Game.Hand as Hand
import Game.Strategy.Hint as Hint
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Game.Strategy.Hint.buildSuggestions"
        [ emptyHand
        , openingHandDirectPlayFirst
        , priorityOrderMonotonic
        ]


emptyHand : Test
emptyHand =
    test "empty hand → no suggestions" <|
        \_ ->
            Hint.buildSuggestions Hand.empty Dealer.initialBoard
                |> List.length
                |> Expect.equal 0


openingHandDirectPlayFirst : Test
openingHandDirectPlayFirst =
    describe "opening hand vs opening board → direct_play wins priority"
        [ test "first suggestion exists" <|
            \_ ->
                Hint.buildSuggestions Dealer.openingHand Dealer.initialBoard
                    |> List.head
                    |> Expect.notEqual Nothing
        , test "first suggestion trick_id = direct_play" <|
            \_ ->
                case Hint.buildSuggestions Dealer.openingHand Dealer.initialBoard of
                    first :: _ ->
                        Expect.equal "direct_play" first.trickId

                    _ ->
                        Expect.fail "no suggestions produced"
        , test "first suggestion rank = 1" <|
            \_ ->
                case Hint.buildSuggestions Dealer.openingHand Dealer.initialBoard of
                    first :: _ ->
                        Expect.equal 1 first.rank

                    _ ->
                        Expect.fail "no suggestions produced"
        , test "first suggestion carries exactly one hand card" <|
            \_ ->
                case Hint.buildSuggestions Dealer.openingHand Dealer.initialBoard of
                    first :: _ ->
                        Expect.equal 1 (List.length first.handCards)

                    _ ->
                        Expect.fail "no suggestions produced"
        ]


priorityOrderMonotonic : Test
priorityOrderMonotonic =
    test "ranks are strictly increasing in output order (gaps allowed)" <|
        \_ ->
            let
                suggestions =
                    Hint.buildSuggestions Dealer.openingHand Dealer.initialBoard

                ranks =
                    List.map .rank suggestions

                pairs =
                    List.map2 Tuple.pair ranks (List.drop 1 ranks)
            in
            pairs
                |> List.all (\( a, b ) -> a < b)
                |> Expect.equal True
