module Game.Strategy.PairPeel exposing (trick)

{-| PAIR\_PEEL: two hand cards form a pair (set-pair or run-pair)
and a peelable board card completes the triplet.

Mirrors `angry-gopher/lynrummy/tricks/pair_peel.go`.

-}

import Game.Card
    exposing
        ( Card
        , CardColor(..)
        , CardValue
        , Suit(..)
        , cardValueToInt
        , suitColor
        )
import Game.CardStack
    exposing
        ( CardStack
        , HandCard
        , canExtract
        )
import Game.StackType exposing (CardStackType(..), getStackType, predecessor, successor)
import Game.Strategy.Helpers exposing (dummyLoc, extractCard, freshlyPlayed)
import Game.Strategy.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "pair_peel"
    , description = "Peel a board card to complete a pair in your hand."
    , findPlays = findPlays
    }


type alias PairNeed =
    { value : CardValue
    , suits : List Suit
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand board =
    handPairs hand
        |> List.concatMap
            (\( hca, hcb ) ->
                pairNeeds hca.card hcb.card
                    |> List.concatMap
                        (\need ->
                            scanBoardForNeed board need
                                |> List.map
                                    (\( si, ci, targetCard ) ->
                                        makePlay hca hcb si ci targetCard
                                    )
                        )
            )


{-| All i < j pairs of distinct hand cards. Skips equal cards
(same value + suit + deck) — TS/Go does `!a.equals(b)`.
-}
handPairs : List HandCard -> List ( HandCard, HandCard )
handPairs hand =
    hand
        |> List.indexedMap Tuple.pair
        |> List.concatMap
            (\( i, a ) ->
                hand
                    |> List.indexedMap Tuple.pair
                    |> List.filterMap
                        (\( j, b ) ->
                            if j > i && not (cardsEqual a.card b.card) then
                                Just ( a, b )

                            else
                                Nothing
                        )
            )


cardsEqual : Card -> Card -> Bool
cardsEqual a b =
    a.value == b.value && a.suit == b.suit && a.originDeck == b.originDeck


{-| What card(s) would complete this pair? Returns zero or more
needs.
-}
pairNeeds : Card -> Card -> List PairNeed
pairNeeds a b =
    if a.value == b.value && a.suit /= b.suit then
        -- Set pair: a third distinct suit.
        let
            allSuits =
                [ Heart, Spade, Diamond, Club ]

            rem =
                List.filter (\s -> s /= a.suit && s /= b.suit) allSuits
        in
        [ { value = a.value, suits = rem } ]

    else
        let
            ( lo, hi ) =
                if cardValueToInt a.value < cardValueToInt b.value then
                    ( a, b )

                else
                    ( b, a )
        in
        if hi.value /= successor lo.value then
            []

        else if a.suit == b.suit then
            -- Pure-run pair.
            [ { value = predecessor lo.value, suits = [ lo.suit ] }
            , { value = successor hi.value, suits = [ hi.suit ] }
            ]

        else if suitColor a.suit /= suitColor b.suit then
            -- Rb-run pair.
            let
                oppLo =
                    oppositeColorSuits (suitColor lo.suit)

                oppHi =
                    oppositeColorSuits (suitColor hi.suit)
            in
            [ { value = predecessor lo.value, suits = oppLo }
            , { value = successor hi.value, suits = oppHi }
            ]

        else
            []


oppositeColorSuits : CardColor -> List Suit
oppositeColorSuits c =
    if c == Red then
        [ Spade, Club ]

    else
        [ Heart, Diamond ]


scanBoardForNeed : List CardStack -> PairNeed -> List ( Int, Int, Card )
scanBoardForNeed board need =
    List.indexedMap Tuple.pair board
        |> List.concatMap
            (\( si, stack ) ->
                List.indexedMap Tuple.pair stack.boardCards
                    |> List.filterMap
                        (\( ci, bc ) ->
                            if
                                bc.card.value
                                    == need.value
                                    && List.member bc.card.suit need.suits
                                    && canExtract stack ci
                            then
                                Just ( si, ci, bc.card )

                            else
                                Nothing
                        )
            )


makePlay : HandCard -> HandCard -> Int -> Int -> Card -> Play
makePlay hca hcb si ci targetCard =
    { trickId = "pair_peel"
    , handCards = [ hca, hcb ]
    , apply = applyPairPeel hca hcb si ci targetCard
    }


applyPairPeel : HandCard -> HandCard -> Int -> Int -> Card -> List CardStack -> ( List CardStack, List HandCard )
applyPairPeel hca hcb si ci peelTarget board =
    case List.drop si board |> List.head of
        Nothing ->
            ( board, [] )

        Just stack ->
            case List.drop ci stack.boardCards |> List.head of
                Nothing ->
                    ( board, [] )

                Just bc ->
                    if not (cardsEqual bc.card peelTarget) then
                        ( board, [] )

                    else if not (canExtract stack ci) then
                        ( board, [] )

                    else
                        let
                            ( board2, maybeExt ) =
                                extractCard board si ci
                        in
                        case maybeExt of
                            Nothing ->
                                ( board, [] )

                            Just extracted ->
                                let
                                    group =
                                        [ freshlyPlayed hca
                                        , freshlyPlayed hcb
                                        , extracted
                                        ]
                                            |> List.sortBy (.card >> .value >> cardValueToInt)

                                    newStack =
                                        { boardCards = group, loc = dummyLoc }

                                    resultType =
                                        getStackType (List.map .card group)
                                in
                                if resultType == Bogus || resultType == Dup || resultType == Incomplete then
                                    ( board, [] )

                                else
                                    ( board2 ++ [ newStack ], [ hca, hcb ] )
