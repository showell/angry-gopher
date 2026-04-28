module Game.StackTypeTest exposing (suite)

{-| Tests for `Game.Rules.StackType`. Ported from
`angry-cat/src/lyn_rummy/core/stack_type_test.ts`.

Covers: `getStackType` classification over representative hands,
`valueDistance` cyclic properties, `successor` / `predecessor`
wrap behavior.

Past-Claude's TS tests covered `getStackType` and `valueDistance`
thoroughly; `successor` / `predecessor` weren't tested directly
in the source. Current-Claude adds a small set for those two —
cheap coverage on a pair of foundational functions the referee
will rely on.

-}

import Expect
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), allCardValues, allSuits, cardFromLabel, valueStr)
import Game.Rules.StackType
    exposing
        ( CardStackType(..)
        , getStackType
        , isLegalStack
        , isPartialOk
        , neighbors
        , predecessor
        , successor
        , valueDistance
        )
import Test exposing (Test, describe, test)



-- HELPERS


{-| Parse a list of labels into cards, all from DeckOne.
Fails the test if any label is malformed.
-}
cardsFromLabels : List String -> List Card
cardsFromLabels labels =
    List.filterMap (\l -> cardFromLabel l DeckOne) labels


{-| Shortcuts for the two-deck scenarios.
-}
fromD1 : String -> Card
fromD1 label =
    cardFromLabel label DeckOne
        |> Maybe.withDefault fallbackCard


fromD2 : String -> Card
fromD2 label =
    cardFromLabel label DeckTwo
        |> Maybe.withDefault fallbackCard


{-| Only used as a Maybe.withDefault guard. If a test ever
falls through to this, the label was malformed — treat as a test
bug.
-}
fallbackCard : Card
fallbackCard =
    { value = Ace, suit = Club, originDeck = DeckOne }



-- SUITE


suite : Test
suite =
    describe "Game.Rules.StackType"
        [ getStackTypeTests
        , valueDistanceTests
        , successorTests
        , predecessorTests
        , isLegalStackTests
        , isPartialOkTests
        , neighborsTests
        , pureRunMonotonicTests
        , setPermutationInvariantTests
        , valueDistanceTriangleTests
        , successorPredecessorCycleTests
        , isPartialOkBoundaryTests
        , neighborsShapeTests
        ]


getStackTypeTests : Test
getStackTypeTests =
    describe "getStackType"
        [ describe "too few cards"
            [ test "empty -> Incomplete" <|
                \_ -> Expect.equal Incomplete (getStackType [])
            , test "single card -> Incomplete" <|
                \_ -> Expect.equal Incomplete (getStackType (cardsFromLabels [ "AH" ]))
            , test "two cards -> Incomplete" <|
                \_ -> Expect.equal Incomplete (getStackType (cardsFromLabels [ "AH", "2H" ]))
            ]
        , describe "pure run (same suit, sequential)"
            [ test "AH 2H 3H is PureRun" <|
                \_ -> Expect.equal PureRun (getStackType (cardsFromLabels [ "AH", "2H", "3H" ]))
            , test "TD JD QD KD is PureRun" <|
                \_ -> Expect.equal PureRun (getStackType (cardsFromLabels [ "TD", "JD", "QD", "KD" ]))
            , test "KS AS 2S is PureRun (K wraps to A)" <|
                \_ -> Expect.equal PureRun (getStackType (cardsFromLabels [ "KS", "AS", "2S" ]))
            ]
        , describe "red/black alternating run"
            [ test "AH 2S 3H is RedBlackRun" <|
                \_ -> Expect.equal RedBlackRun (getStackType (cardsFromLabels [ "AH", "2S", "3H" ]))
            , test "AC 2H 3C 4H is RedBlackRun" <|
                \_ -> Expect.equal RedBlackRun (getStackType (cardsFromLabels [ "AC", "2H", "3C", "4H" ]))
            ]
        , describe "set (same value, different suits, no dups)"
            [ test "7S 7D 7C is Set" <|
                \_ -> Expect.equal Set (getStackType (cardsFromLabels [ "7S", "7D", "7C" ]))
            , test "AC AD AH AS is Set (full four)" <|
                \_ -> Expect.equal Set (getStackType (cardsFromLabels [ "AC", "AD", "AH", "AS" ]))
            ]
        , describe "dup (same value and suit)"
            [ test "two AH from different decks -> Dup" <|
                \_ ->
                    Expect.equal Dup
                        (getStackType [ fromD1 "AH", fromD2 "AH" ])
            , test "a provisional set that contains a dup -> Dup" <|
                \_ ->
                    Expect.equal Dup
                        (getStackType [ fromD1 "7S", fromD2 "7S", fromD1 "7D" ])
            ]
        , describe "bogus (inconsistent or invalid)"
            [ test "wrong order for a run (3H 2H AH)" <|
                \_ -> Expect.equal Bogus (getStackType (cardsFromLabels [ "3H", "2H", "AH" ]))
            , test "mixed stack types (AH 2H 3D)" <|
                \_ -> Expect.equal Bogus (getStackType (cardsFromLabels [ "AH", "2H", "3D" ]))
            , test "mixing set and run (AH 2H 2D)" <|
                \_ -> Expect.equal Bogus (getStackType (cardsFromLabels [ "AH", "2H", "2D" ]))
            ]
        ]


valueDistanceTests : Test
valueDistanceTests =
    describe "valueDistance (cyclic over 13, max 6)"
        [ test "self distance is always 0" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> valueDistance v v == 0)
                    |> Expect.equal True
        , describe "ace's neighborhood (wrap-around case)"
            [ test "Ace <-> King = 1" <| \_ -> Expect.equal 1 (valueDistance Ace King)
            , test "Ace <-> Two = 1" <| \_ -> Expect.equal 1 (valueDistance Ace Two)
            , test "Ace <-> Queen = 2" <| \_ -> Expect.equal 2 (valueDistance Ace Queen)
            , test "Ace <-> Three = 2" <| \_ -> Expect.equal 2 (valueDistance Ace Three)
            , test "Ace <-> Four = 3" <| \_ -> Expect.equal 3 (valueDistance Ace Four)
            , test "Ace <-> Jack = 3" <| \_ -> Expect.equal 3 (valueDistance Ace Jack)
            ]
        , describe "king's neighborhood (other side of wrap)"
            [ test "King <-> Ace = 1" <| \_ -> Expect.equal 1 (valueDistance King Ace)
            , test "King <-> Queen = 1" <| \_ -> Expect.equal 1 (valueDistance King Queen)
            , test "King <-> Two = 2" <| \_ -> Expect.equal 2 (valueDistance King Two)
            ]
        , describe "diametric pairs (max distance 6)"
            [ test "Two <-> Eight = 6" <| \_ -> Expect.equal 6 (valueDistance Two Eight)
            , test "Two <-> Nine = 6" <| \_ -> Expect.equal 6 (valueDistance Two Nine)
            , test "Three <-> Nine = 6" <| \_ -> Expect.equal 6 (valueDistance Three Nine)
            , test "Seven <-> Ace = 6" <| \_ -> Expect.equal 6 (valueDistance Seven Ace)
            , test "Seven <-> King = 6" <| \_ -> Expect.equal 6 (valueDistance Seven King)
            ]
        , test "distance is in [0, 6] everywhere on the cycle" <|
            \_ ->
                let
                    pairs =
                        allCardValues
                            |> List.concatMap (\a -> List.map (\b -> ( a, b )) allCardValues)

                    inRange ( a, b ) =
                        let
                            d =
                                valueDistance a b
                        in
                        d >= 0 && d <= 6
                in
                pairs
                    |> List.all inRange
                    |> Expect.equal True
        , test "distance is symmetric everywhere on the cycle" <|
            \_ ->
                let
                    pairs =
                        allCardValues
                            |> List.concatMap (\a -> List.map (\b -> ( a, b )) allCardValues)

                    symmetric ( a, b ) =
                        valueDistance a b == valueDistance b a
                in
                pairs
                    |> List.all symmetric
                    |> Expect.equal True
        ]


successorTests : Test
successorTests =
    describe "successor (wraps King -> Ace)"
        [ test "Ace -> Two" <| \_ -> Expect.equal Two (successor Ace)
        , test "Nine -> Ten" <| \_ -> Expect.equal Ten (successor Nine)
        , test "King -> Ace (wrap)" <| \_ -> Expect.equal Ace (successor King)
        , test "K, A, 2 chain via successor" <|
            \_ ->
                Expect.equal [ Ace, Two ]
                    [ successor King, successor (successor King) ]
        , test "applying successor 13 times returns to start" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> apply 13 successor v == v)
                    |> Expect.equal True
        ]


predecessorTests : Test
predecessorTests =
    describe "predecessor (wraps Ace -> King)"
        [ test "Two -> Ace" <| \_ -> Expect.equal Ace (predecessor Two)
        , test "Ace -> King (wrap)" <| \_ -> Expect.equal King (predecessor Ace)
        , test "predecessor is inverse of successor everywhere" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> predecessor (successor v) == v)
                    |> Expect.equal True
        ]



-- RULE PREDICATES (migrated from Game.Agent.CardsTest, 2026-04-28)
--
-- isLegalStack / isPartialOk / neighbors moved out of
-- Game.Agent.Cards into Game.Rules.StackType in phase 2b of
-- the rules-lockdown plan; tests followed.


isLegalStackTests : Test
isLegalStackTests =
    describe "isLegalStack"
        [ test "3-set classifies legal" <|
            \_ ->
                isLegalStack
                    [ fromD1 "5C", fromD1 "5D", fromD1 "5S" ]
                    |> Expect.equal True
        , test "3-card pure run classifies legal" <|
            \_ ->
                isLegalStack
                    [ fromD1 "5H", fromD1 "6H", fromD1 "7H" ]
                    |> Expect.equal True
        , test "3-card rb-run classifies legal" <|
            \_ ->
                isLegalStack
                    [ fromD1 "5H", fromD1 "6S", fromD1 "7H" ]
                    |> Expect.equal True
        , test "2-card stack is not yet legal" <|
            \_ ->
                isLegalStack
                    [ fromD1 "5H", fromD1 "6H" ]
                    |> Expect.equal False
        , test "wraparound K-A-2 pure run is legal" <|
            \_ ->
                isLegalStack
                    [ fromD1 "KH", fromD1 "AH", fromD1 "2H" ]
                    |> Expect.equal True
        ]


isPartialOkTests : Test
isPartialOkTests =
    describe "isPartialOk"
        [ test "empty stack is OK" <|
            \_ -> isPartialOk [] |> Expect.equal True
        , test "singleton is OK" <|
            \_ ->
                isPartialOk [ fromD1 "5H" ]
                    |> Expect.equal True
        , test "consecutive same-suit pair is OK (pure-run partial)" <|
            \_ ->
                isPartialOk [ fromD1 "5H", fromD1 "6H" ]
                    |> Expect.equal True
        , test "consecutive opposite-color pair is OK (rb-run partial)" <|
            \_ ->
                isPartialOk [ fromD1 "5H", fromD1 "6C" ]
                    |> Expect.equal True
        , test "same-value distinct-suit pair is OK (set partial)" <|
            \_ ->
                isPartialOk [ fromD1 "5H", fromD1 "5C" ]
                    |> Expect.equal True
        , test "non-consecutive pair is NOT ok" <|
            \_ ->
                isPartialOk [ fromD1 "5H", fromD1 "9H" ]
                    |> Expect.equal False
        , test "consecutive same-color (different suits) NOT ok" <|
            \_ ->
                isPartialOk [ fromD1 "5H", fromD1 "6D" ]
                    |> Expect.equal False
        , test "3+ legal stack delegates to isLegalStack" <|
            \_ ->
                isPartialOk
                    [ fromD1 "5H", fromD1 "6H", fromD1 "7H" ]
                    |> Expect.equal True
        ]


neighborsTests : Test
neighborsTests =
    describe "neighbors"
        [ test "5H neighbors include 4H and 6H (pure-run)" <|
            \_ ->
                let
                    ns =
                        neighbors (fromD1 "5H")

                    h4 =
                        ( (fromD1 "4H").value, (fromD1 "4H").suit )

                    h6 =
                        ( (fromD1 "6H").value, (fromD1 "6H").suit )
                in
                Expect.all
                    [ \_ -> Expect.equal True (List.member h4 ns)
                    , \_ -> Expect.equal True (List.member h6 ns)
                    ]
                    ()
        , test "5H neighbors include opposite-color ±1 (rb-run)" <|
            \_ ->
                let
                    ns =
                        neighbors (fromD1 "5H")

                    c4 =
                        ( (fromD1 "4C").value, (fromD1 "4C").suit )

                    s6 =
                        ( (fromD1 "6S").value, (fromD1 "6S").suit )
                in
                Expect.all
                    [ \_ -> Expect.equal True (List.member c4 ns)
                    , \_ -> Expect.equal True (List.member s6 ns)
                    ]
                    ()
        , test "5H neighbors include 5C, 5D, 5S (set partners)" <|
            \_ ->
                let
                    ns =
                        neighbors (fromD1 "5H")

                    c5 =
                        ( (fromD1 "5C").value, (fromD1 "5C").suit )

                    d5 =
                        ( (fromD1 "5D").value, (fromD1 "5D").suit )

                    s5 =
                        ( (fromD1 "5S").value, (fromD1 "5S").suit )
                in
                Expect.all
                    [ \_ -> Expect.equal True (List.member c5 ns)
                    , \_ -> Expect.equal True (List.member d5 ns)
                    , \_ -> Expect.equal True (List.member s5 ns)
                    ]
                    ()
        , test "5H neighbors do NOT include 5H itself" <|
            \_ ->
                let
                    ns =
                        neighbors (fromD1 "5H")

                    h5 =
                        ( (fromD1 "5H").value, (fromD1 "5H").suit )
                in
                List.member h5 ns
                    |> Expect.equal False
        ]



-- small helper used above


apply : Int -> (a -> a) -> a -> a
apply n f x =
    if n <= 0 then
        x

    else
        apply (n - 1) f (f x)



-- CLASS-1 LOCKDOWN TESTS (added 2026-04-28, phase 3 of game_rules_lockdown)
--
-- Per `feedback_segregate_by_volatility_class.md`: Class-1
-- rules get exhaustive snapshot-style tests. The functions
-- below all encode game-rule invariants that should never
-- drift; tests are deliberately brittle so any future
-- regression breaks loudly.
--
-- Style choice: enumerate-and-check over `allCardValues` /
-- `allSuits` rather than fuzz. The domain is finite (13
-- values, 4 suits) so the property tests are exhaustive,
-- not statistical. Existing tests in this file already use
-- this idiom (see `valueDistanceTests`, `successorTests`).


pureRunMonotonicTests : Test
pureRunMonotonicTests =
    describe "getStackType: PureRun monotonic in length 3..13"
        -- For one suit, every prefix of length n in [3..13] of
        -- the canonical Ace-through-King run classifies as
        -- PureRun. This locks the "longer is still legal"
        -- property of pure-run classification.
        [ test "all prefixes of A..K of Hearts (length 3..13) are PureRun" <|
            \_ ->
                let
                    fullRun =
                        List.map
                            (\v -> { value = v, suit = Heart, originDeck = DeckOne })
                            allCardValues

                    prefix n xs =
                        List.take n xs

                    lengths =
                        List.range 3 13
                in
                lengths
                    |> List.all (\n -> getStackType (prefix n fullRun) == PureRun)
                    |> Expect.equal True
        , test "every suit's full A..K run classifies as PureRun" <|
            \_ ->
                let
                    runOf suit =
                        List.map
                            (\v -> { value = v, suit = suit, originDeck = DeckOne })
                            allCardValues
                in
                allSuits
                    |> List.all (\s -> getStackType (runOf s) == PureRun)
                    |> Expect.equal True
        , test "K-A-2-...-Q full wraparound (one suit) is PureRun" <|
            \_ ->
                -- Rotate the canonical run so it starts at King
                -- and wraps back through Queen. Lyn Rummy's K->A
                -- wrap means this is still a single PureRun.
                let
                    rotated =
                        [ King
                        , Ace
                        , Two
                        , Three
                        , Four
                        , Five
                        , Six
                        , Seven
                        , Eight
                        , Nine
                        , Ten
                        , Jack
                        , Queen
                        ]

                    cards =
                        List.map
                            (\v -> { value = v, suit = Spade, originDeck = DeckOne })
                            rotated
                in
                Expect.equal PureRun (getStackType cards)
        ]


setPermutationInvariantTests : Test
setPermutationInvariantTests =
    describe "getStackType: Set classification invariant under permutation"
        -- A set is unordered semantically (no successor
        -- relation between members). Any permutation of a valid
        -- set must still classify as Set.
        [ test "all permutations of {7C, 7D, 7S} classify as Set" <|
            \_ ->
                let
                    c7 =
                        fromD1 "7C"

                    d7 =
                        fromD1 "7D"

                    s7 =
                        fromD1 "7S"

                    allPermutations =
                        [ [ c7, d7, s7 ]
                        , [ c7, s7, d7 ]
                        , [ d7, c7, s7 ]
                        , [ d7, s7, c7 ]
                        , [ s7, c7, d7 ]
                        , [ s7, d7, c7 ]
                        ]
                in
                allPermutations
                    |> List.all (\p -> getStackType p == Set)
                    |> Expect.equal True
        , test "all 24 permutations of full 4-set {AC, AD, AH, AS} classify as Set" <|
            \_ ->
                let
                    ac =
                        fromD1 "AC"

                    ad =
                        fromD1 "AD"

                    ah =
                        fromD1 "AH"

                    aspade =
                        fromD1 "AS"

                    -- Hand-rolled 24 permutations of [ac, ad, ah, aspade].
                    perms =
                        [ [ ac, ad, ah, aspade ]
                        , [ ac, ad, aspade, ah ]
                        , [ ac, ah, ad, aspade ]
                        , [ ac, ah, aspade, ad ]
                        , [ ac, aspade, ad, ah ]
                        , [ ac, aspade, ah, ad ]
                        , [ ad, ac, ah, aspade ]
                        , [ ad, ac, aspade, ah ]
                        , [ ad, ah, ac, aspade ]
                        , [ ad, ah, aspade, ac ]
                        , [ ad, aspade, ac, ah ]
                        , [ ad, aspade, ah, ac ]
                        , [ ah, ac, ad, aspade ]
                        , [ ah, ac, aspade, ad ]
                        , [ ah, ad, ac, aspade ]
                        , [ ah, ad, aspade, ac ]
                        , [ ah, aspade, ac, ad ]
                        , [ ah, aspade, ad, ac ]
                        , [ aspade, ac, ad, ah ]
                        , [ aspade, ac, ah, ad ]
                        , [ aspade, ad, ac, ah ]
                        , [ aspade, ad, ah, ac ]
                        , [ aspade, ah, ac, ad ]
                        , [ aspade, ah, ad, ac ]
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 24 (List.length perms)
                    , \_ ->
                        perms
                            |> List.all (\p -> getStackType p == Set)
                            |> Expect.equal True
                    ]
                    ()
        ]


valueDistanceTriangleTests : Test
valueDistanceTriangleTests =
    describe "valueDistance: triangle inequality (exhaustive over 13^3)"
        -- d(a,c) <= d(a,b) + d(b,c) for every triple. With 13
        -- values this is 2197 triples — cheap to enumerate.
        [ test "triangle inequality holds for all (a, b, c) in CardValue^3" <|
            \_ ->
                let
                    triples =
                        allCardValues
                            |> List.concatMap
                                (\a ->
                                    List.concatMap
                                        (\b ->
                                            List.map (\c -> ( a, b, c )) allCardValues
                                        )
                                        allCardValues
                                )

                    holds ( a, b, c ) =
                        valueDistance a c
                            <= valueDistance a b
                            + valueDistance b c
                in
                Expect.all
                    [ \_ -> Expect.equal 2197 (List.length triples)
                    , \_ ->
                        triples
                            |> List.all holds
                            |> Expect.equal True
                    ]
                    ()
        ]


successorPredecessorCycleTests : Test
successorPredecessorCycleTests =
    describe "successor / predecessor: total + cyclic + inverse"
        -- The pre-existing tests cover predecessor∘successor=id
        -- and successor^13=id. Add the symmetric checks so any
        -- one-sided regression breaks.
        [ test "successor (predecessor v) == v for every value" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> successor (predecessor v) == v)
                    |> Expect.equal True
        , test "applying predecessor 13 times returns to start" <|
            \_ ->
                allCardValues
                    |> List.all (\v -> apply 13 predecessor v == v)
                    |> Expect.equal True
        , test "successor is a bijection over CardValue (image has 13 distinct values)" <|
            \_ ->
                let
                    image =
                        List.map (successor >> valueStr) allCardValues
                            |> List.sort
                in
                Expect.equal 13 (List.length image)
        ]


isPartialOkBoundaryTests : Test
isPartialOkBoundaryTests =
    describe "isPartialOk: boundary cases at length 0/1/2/3"
        -- The pre-existing tests cover representative cases.
        -- These add the explicit length boundary: at length 3+
        -- the function must coincide with isLegalStack.
        [ test "length-3 result equals isLegalStack result (legal)" <|
            \_ ->
                let
                    stack =
                        [ fromD1 "5H", fromD1 "6H", fromD1 "7H" ]
                in
                Expect.equal (isLegalStack stack) (isPartialOk stack)
        , test "length-3 result equals isLegalStack result (illegal)" <|
            \_ ->
                -- A non-consecutive trio: bogus, so neither
                -- legal nor partial-ok. Both predicates agree.
                let
                    stack =
                        [ fromD1 "5H", fromD1 "8H", fromD1 "TH" ]
                in
                Expect.equal (isLegalStack stack) (isPartialOk stack)
        , test "length-4 result equals isLegalStack (delegates)" <|
            \_ ->
                let
                    stack =
                        [ fromD1 "5H", fromD1 "6H", fromD1 "7H", fromD1 "8H" ]
                in
                Expect.equal (isLegalStack stack) (isPartialOk stack)
        , test "every two-card pair classified as set-partial is also partial-ok" <|
            \_ ->
                -- Same-value distinct-suit pair lifted across
                -- all values: 13 pairs, each must be partial-ok.
                let
                    pairs =
                        List.map
                            (\v ->
                                [ { value = v, suit = Heart, originDeck = DeckOne }
                                , { value = v, suit = Spade, originDeck = DeckOne }
                                ]
                            )
                            allCardValues
                in
                pairs
                    |> List.all isPartialOk
                    |> Expect.equal True
        , test "every two-card pure-run partial (consecutive same suit) is partial-ok" <|
            \_ ->
                -- For every (suit, value), (v, succ v, sameSuit)
                -- is a pure-run partial. 13 * 4 = 52 pairs.
                let
                    pairs =
                        List.concatMap
                            (\s ->
                                List.map
                                    (\v ->
                                        [ { value = v, suit = s, originDeck = DeckOne }
                                        , { value = next v, suit = s, originDeck = DeckOne }
                                        ]
                                    )
                                    allCardValues
                            )
                            allSuits
                in
                pairs
                    |> List.all isPartialOk
                    |> Expect.equal True
        ]


neighborsShapeTests : Test
neighborsShapeTests =
    describe "neighbors: shape stability and cardinality bound"
        -- `neighbors` is a pure function of (value, suit). The
        -- contract: for any card, exactly 9 neighbor-shapes are
        -- returned (2 pure-run partners + 4 rb-run partners +
        -- 3 set partners). The card itself is never a neighbor.
        [ test "every card (over all 104 reachable) has exactly 9 neighbors" <|
            \_ ->
                let
                    allCards =
                        List.concatMap
                            (\v ->
                                List.concatMap
                                    (\s ->
                                        [ { value = v, suit = s, originDeck = DeckOne }
                                        , { value = v, suit = s, originDeck = DeckTwo }
                                        ]
                                    )
                                    allSuits
                            )
                            allCardValues
                in
                allCards
                    |> List.all (\c -> List.length (neighbors c) == 9)
                    |> Expect.equal True
        , test "neighbors is deck-agnostic (DeckOne and DeckTwo same input give same output)" <|
            \_ ->
                let
                    pairs =
                        List.concatMap
                            (\v ->
                                List.map
                                    (\s ->
                                        ( { value = v, suit = s, originDeck = DeckOne }
                                        , { value = v, suit = s, originDeck = DeckTwo }
                                        )
                                    )
                                    allSuits
                            )
                            allCardValues
                in
                pairs
                    |> List.all (\( a, b ) -> neighbors a == neighbors b)
                    |> Expect.equal True
        , test "no card is its own (value, suit) neighbor" <|
            \_ ->
                let
                    allCards =
                        List.concatMap
                            (\v ->
                                List.map
                                    (\s ->
                                        { value = v, suit = s, originDeck = DeckOne }
                                    )
                                    allSuits
                            )
                            allCardValues

                    selfTuple c =
                        ( c.value, c.suit )

                    selfMissing c =
                        not (List.member (selfTuple c) (neighbors c))
                in
                allCards
                    |> List.all selfMissing
                    |> Expect.equal True
        , test "neighbor shapes are pairwise distinct (set has 9 entries)" <|
            \_ ->
                -- Use one representative card per (value, suit)
                -- combination; the 9 returned tuples must not
                -- contain duplicates.
                let
                    allCards =
                        List.concatMap
                            (\v ->
                                List.map
                                    (\s ->
                                        { value = v, suit = s, originDeck = DeckOne }
                                    )
                                    allSuits
                            )
                            allCardValues

                    tupleKey ( v, s ) =
                        cardValueIntFor v * 10 + suitIntFor s

                    distinct ns =
                        let
                            keys =
                                List.map tupleKey ns
                        in
                        List.length keys
                            == List.length (dedupSorted (List.sort keys))
                in
                allCards
                    |> List.all (\c -> distinct (neighbors c))
                    |> Expect.equal True
        ]



-- helpers used by neighbor-shape tests


cardValueIntFor : CardValue -> Int
cardValueIntFor v =
    -- We avoid importing cardValueToInt to keep the test
    -- module's import surface minimal; this is just a key
    -- function for de-duplication, not under test.
    case List.head (List.filter (\( vv, _ ) -> vv == v) cardValueIndex) of
        Just ( _, n ) ->
            n

        Nothing ->
            0


cardValueIndex : List ( CardValue, Int )
cardValueIndex =
    List.indexedMap (\i v -> ( v, i + 1 )) allCardValues


suitIntFor : Suit -> Int
suitIntFor s =
    case List.head (List.filter (\( ss, _ ) -> ss == s) suitIndex) of
        Just ( _, n ) ->
            n

        Nothing ->
            0


suitIndex : List ( Suit, Int )
suitIndex =
    List.indexedMap (\i s -> ( s, i )) allSuits


dedupSorted : List Int -> List Int
dedupSorted xs =
    case xs of
        [] ->
            []

        [ x ] ->
            [ x ]

        x :: y :: rest ->
            if x == y then
                dedupSorted (y :: rest)

            else
                x :: dedupSorted (y :: rest)


next : CardValue -> CardValue
next =
    successor
