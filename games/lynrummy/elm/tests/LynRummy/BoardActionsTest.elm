module LynRummy.BoardActionsTest exposing (suite)

{-| Tests for `LynRummy.BoardActions`. Ported from
`angry-cat/src/lyn_rummy/game/board_actions_test.ts`.
-}

import Expect
import LynRummy.BoardActions as BA
    exposing
        ( BoardChange
        , Side(..)
        )
import LynRummy.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardFromLabel)
import LynRummy.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCard
        , HandCardState(..)
        , size
        )
import Test exposing (Test, describe, test)



-- HELPERS


origin : BoardLocation
origin =
    { top = 0, left = 0 }


fallback : Card
fallback =
    { value = Ace, suit = Club, originDeck = DeckOne }


card : String -> Card
card label =
    cardFromLabel label DeckOne |> Maybe.withDefault fallback


bs : List String -> CardStack
bs labels =
    { boardCards =
        List.map
            (\l -> { card = card l, state = FirmlyOnBoard })
            labels
    , loc = origin
    }


hc : String -> HandCard
hc label =
    { card = card label, state = HandNormal }



-- SUITE


suite : Test
suite =
    describe "LynRummy.BoardActions"
        [ handMergeRightTests
        , handMergeLeftTests
        , handMergeRejectedTests
        , stackMergeRightTests
        , stackMergeWrongDirectionTests
        , placeHandCardTests
        , moveStackTests
        , findAllStackMergesTests
        , findAllHandMergesTests
        , duplicateHandMergeRejectedTests
        ]


handMergeRightTests : Test
handMergeRightTests =
    describe "tryHandMerge 7H onto right of [4H 5H 6H]"
        [ test "produces a valid BoardChange" <|
            \_ ->
                case BA.tryHandMerge (bs [ "4H", "5H", "6H" ]) (hc "7H") Right of
                    Nothing ->
                        Expect.fail "7H should merge right onto hearts run"

                    Just change ->
                        Expect.all
                            [ \_ -> Expect.equal 1 (List.length change.stacksToRemove)
                            , \_ -> Expect.equal 1 (List.length change.stacksToAdd)
                            , \_ ->
                                case change.stacksToAdd of
                                    [ merged ] ->
                                        Expect.equal 4 (size merged)

                                    _ ->
                                        Expect.fail "expected single merged stack"
                            , \_ -> Expect.equal 1 (List.length change.handCardsToRelease)
                            ]
                            ()
        ]


handMergeLeftTests : Test
handMergeLeftTests =
    describe "tryHandMerge 3H onto left of [4H 5H 6H]"
        [ test "produces a 4-card merge" <|
            \_ ->
                case BA.tryHandMerge (bs [ "4H", "5H", "6H" ]) (hc "3H") Left of
                    Nothing ->
                        Expect.fail "3H should merge left"

                    Just change ->
                        case change.stacksToAdd of
                            [ merged ] ->
                                Expect.equal 4 (size merged)

                            _ ->
                                Expect.fail "expected single merged stack"
        ]


handMergeRejectedTests : Test
handMergeRejectedTests =
    describe "tryHandMerge KS onto [4H 5H 6H] — rejected on both sides"
        [ test "left side rejected" <|
            \_ ->
                Expect.equal Nothing
                    (BA.tryHandMerge (bs [ "4H", "5H", "6H" ]) (hc "KS") Left)
        , test "right side rejected" <|
            \_ ->
                Expect.equal Nothing
                    (BA.tryHandMerge (bs [ "4H", "5H", "6H" ]) (hc "KS") Right)
        ]


stackMergeRightTests : Test
stackMergeRightTests =
    describe "tryStackMerge [4H 5H 6H] right with [7H 8H 9H]"
        [ test "produces 6-card merge, removes both, no hand cards" <|
            \_ ->
                case BA.tryStackMerge (bs [ "4H", "5H", "6H" ]) (bs [ "7H", "8H", "9H" ]) Right of
                    Nothing ->
                        Expect.fail "runs should merge"

                    Just change ->
                        Expect.all
                            [ \_ -> Expect.equal 2 (List.length change.stacksToRemove)
                            , \_ ->
                                case change.stacksToAdd of
                                    [ merged ] ->
                                        Expect.equal 6 (size merged)

                                    _ ->
                                        Expect.fail "expected single merged stack"
                            , \_ -> Expect.equal 0 (List.length change.handCardsToRelease)
                            ]
                            ()
        ]


stackMergeWrongDirectionTests : Test
stackMergeWrongDirectionTests =
    describe "tryStackMerge [4H 5H 6H] left with [7H 8H 9H] — doesn't fit"
        [ test "left-direction merge is rejected" <|
            \_ ->
                Expect.equal Nothing
                    (BA.tryStackMerge (bs [ "4H", "5H", "6H" ]) (bs [ "7H", "8H", "9H" ]) Left)
        ]


placeHandCardTests : Test
placeHandCardTests =
    describe "placeHandCard: single-card stack on empty board"
        [ test "0 removals, 1 add of size 1, 1 hand release" <|
            \_ ->
                let
                    change =
                        BA.placeHandCard (hc "KS") { top = 100, left = 200 }
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (List.length change.stacksToRemove)
                    , \_ -> Expect.equal 1 (List.length change.stacksToAdd)
                    , \_ ->
                        case change.stacksToAdd of
                            [ s ] ->
                                Expect.equal 1 (size s)

                            _ ->
                                Expect.fail "expected single added stack"
                    , \_ -> Expect.equal 1 (List.length change.handCardsToRelease)
                    ]
                    ()
        ]


moveStackTests : Test
moveStackTests =
    describe "moveStack: same cards, new loc"
        [ test "removes old, adds at new loc, no hand cards" <|
            \_ ->
                let
                    stack =
                        bs [ "4H", "5H", "6H" ]

                    change =
                        BA.moveStack stack { top = 50, left = 300 }
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (List.length change.stacksToRemove)
                    , \_ -> Expect.equal 1 (List.length change.stacksToAdd)
                    , \_ ->
                        case change.stacksToAdd of
                            [ s ] ->
                                Expect.all
                                    [ \_ -> Expect.equal 3 (size s)
                                    , \_ -> Expect.equal 300 s.loc.left
                                    ]
                                    ()

                            _ ->
                                Expect.fail "expected single stack"
                    , \_ -> Expect.equal 0 (List.length change.handCardsToRelease)
                    ]
                    ()
        ]


findAllStackMergesTests : Test
findAllStackMergesTests =
    describe "findAllStackMerges"
        [ test "[4H 5H 6H] over [4H 5H 6H; 7H 8H 9H; KS KD KH] -> 1 merge (right with 7H 8H 9H)" <|
            \_ ->
                let
                    stacks =
                        [ bs [ "4H", "5H", "6H" ]
                        , bs [ "7H", "8H", "9H" ]
                        , bs [ "KS", "KD", "KH" ]
                        ]

                    target =
                        bs [ "4H", "5H", "6H" ]

                    merges =
                        BA.findAllStackMerges target stacks
                in
                case merges of
                    [ m ] ->
                        Expect.all
                            [ \_ -> Expect.equal Right m.side
                            , \_ ->
                                case m.change.stacksToAdd of
                                    [ merged ] ->
                                        Expect.equal 6 (size merged)

                                    _ ->
                                        Expect.fail "expected single merged stack"
                            ]
                            ()

                    _ ->
                        Expect.fail ("expected 1 merge, got " ++ String.fromInt (List.length merges))
        , test "[KS KD KH] finds no merges in same board" <|
            \_ ->
                let
                    stacks =
                        [ bs [ "4H", "5H", "6H" ]
                        , bs [ "7H", "8H", "9H" ]
                        , bs [ "KS", "KD", "KH" ]
                        ]

                    target =
                        bs [ "KS", "KD", "KH" ]
                in
                Expect.equal 0 (List.length (BA.findAllStackMerges target stacks))
        ]


findAllHandMergesTests : Test
findAllHandMergesTests =
    describe "findAllHandMerges: 7S with [hearts run; 7-set; spade run]"
        [ test "at least one merge (the 7-set)" <|
            \_ ->
                let
                    stacks =
                        [ bs [ "4H", "5H", "6H" ]
                        , bs [ "7H", "7D", "7C" ]
                        , bs [ "8S", "9S", "TS" ]
                        ]

                    merges =
                        BA.findAllHandMerges (hc "7S") stacks
                in
                if List.length merges >= 1 then
                    Expect.pass

                else
                    Expect.fail "expected at least one merge for 7S"
        ]


duplicateHandMergeRejectedTests : Test
duplicateHandMergeRejectedTests =
    describe "duplicate 7H rejected from [7H 7D 7C]"
        [ test "0 merges" <|
            \_ ->
                let
                    stacks =
                        [ bs [ "7H", "7D", "7C" ] ]
                in
                Expect.equal 0 (List.length (BA.findAllHandMerges (hc "7H") stacks))
        ]
