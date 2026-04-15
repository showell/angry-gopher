module LynRummy.Tricks.HandStacks exposing (trick)

{-| HAND_STACKS: the hand already contains 3+ cards that form a
complete set or run — push the whole group onto the board as a
new stack.

Mirrors `angry-gopher/lynrummy/tricks/hand_stacks.go`.

-}

import Dict exposing (Dict)
import LynRummy.Card exposing (Card, cardValueToInt, suitToInt)
import LynRummy.CardStack exposing (CardStack, HandCard)
import LynRummy.StackType exposing (CardStackType(..), getStackType)
import LynRummy.Tricks.Helpers exposing (freshlyPlayed, pushNewStack)
import LynRummy.Tricks.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "hand_stacks"
    , description = "You already have 3+ cards in your hand that form a set or run!"
    , findPlays = findPlays
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand _ =
    findCandidateGroups hand
        |> List.map makePlay


{-| Emit order (must match Go for fixture determinism): sets
first (by value), pure runs (by suit), then rb runs.
-}
findCandidateGroups : List HandCard -> List (List HandCard)
findCandidateGroups hand =
    findSets hand ++ findPureRuns hand ++ findRbRuns hand


findSets : List HandCard -> List (List HandCard)
findSets hand =
    groupByValue hand
        |> Dict.toList
        |> List.filterMap
            (\( _, cards ) ->
                if List.length cards < 3 then
                    Nothing

                else
                    pickValidSet cards
            )


findPureRuns : List HandCard -> List (List HandCard)
findPureRuns hand =
    groupBySuit hand
        |> Dict.toList
        |> List.concatMap
            (\( _, cards ) ->
                longestPureRuns cards
                    |> List.filter (\run -> List.length run >= 3)
            )


{-| groupByValue keys the dict by cardValueToInt.
-}
groupByValue : List HandCard -> Dict Int (List HandCard)
groupByValue hand =
    List.foldr
        (\hc acc ->
            let
                k =
                    cardValueToInt hc.card.value
            in
            Dict.update k
                (\cur ->
                    case cur of
                        Nothing ->
                            Just [ hc ]

                        Just existing ->
                            Just (hc :: existing)
                )
                acc
        )
        Dict.empty
        hand


groupBySuit : List HandCard -> Dict Int (List HandCard)
groupBySuit hand =
    List.foldr
        (\hc acc ->
            let
                k =
                    suitToInt hc.card.suit
            in
            Dict.update k
                (\cur ->
                    case cur of
                        Nothing ->
                            Just [ hc ]

                        Just existing ->
                            Just (hc :: existing)
                )
                acc
        )
        Dict.empty
        hand


{-| Pick one card per distinct suit; return the set if size ≥ 3
AND the group classifies as SET.
-}
pickValidSet : List HandCard -> Maybe (List HandCard)
pickValidSet cards =
    let
        chosen =
            cards
                |> List.foldr
                    (\hc ( seen, acc ) ->
                        let
                            s =
                                suitToInt hc.card.suit
                        in
                        if List.member s seen then
                            ( seen, acc )

                        else
                            ( s :: seen, hc :: acc )
                    )
                    ( [], [] )
                |> Tuple.second
    in
    if List.length chosen < 3 then
        Nothing

    else if getStackType (List.map .card chosen) == Set then
        Just chosen

    else
        Nothing


{-| Find maximal consecutive-value runs inside a same-suit card
list. Dedupes by value (double-deck dups can't both be in a pure
run).
-}
longestPureRuns : List HandCard -> List (List HandCard)
longestPureRuns cards =
    let
        sorted =
            cards
                |> dedupeByValue
                |> List.sortBy (.card >> .value >> cardValueToInt)
    in
    consecutiveRuns sorted


{-| Find rb runs: consider all cards, sort by value, keep
consecutive runs with alternating color.
-}
findRbRuns : List HandCard -> List (List HandCard)
findRbRuns hand =
    let
        sorted =
            hand
                |> dedupeByValue
                |> List.sortBy (.card >> .value >> cardValueToInt)
    in
    rbConsecutiveRuns sorted
        |> List.filter (\run -> List.length run >= 3)


dedupeByValue : List HandCard -> List HandCard
dedupeByValue cards =
    cards
        |> List.foldr
            (\hc ( seen, acc ) ->
                let
                    k =
                        cardValueToInt hc.card.value
                in
                if List.member k seen then
                    ( seen, acc )

                else
                    ( k :: seen, hc :: acc )
            )
            ( [], [] )
        |> Tuple.second


{-| consecutiveRuns assumes cards are sorted by value. Emits only
runs whose classification is a valid group (PureRun /
RedBlackRun / Set — though in the consecutive-same-suit case we
expect PureRun).
-}
consecutiveRuns : List HandCard -> List (List HandCard)
consecutiveRuns sorted =
    let
        ( runs, final ) =
            List.foldl
                (\hc ( acc, current ) ->
                    case current of
                        [] ->
                            ( acc, [ hc ] )

                        prev :: _ ->
                            if cardValueToInt hc.card.value
                                == cardValueToInt prev.card.value
                                + 1
                            then
                                ( acc, hc :: current )

                            else if List.length current >= 3 && isValidGroup (List.reverse current) then
                                ( List.reverse current :: acc, [ hc ] )

                            else
                                ( acc, [ hc ] )
                )
                ( [], [] )
                sorted
    in
    List.reverse
        (if List.length final >= 3 && isValidGroup (List.reverse final) then
            List.reverse final :: runs

         else
            runs
        )


{-| rbConsecutiveRuns is like consecutiveRuns but also requires
alternating colors.
-}
rbConsecutiveRuns : List HandCard -> List (List HandCard)
rbConsecutiveRuns sorted =
    let
        ( runs, final ) =
            List.foldl
                (\hc ( acc, current ) ->
                    case current of
                        [] ->
                            ( acc, [ hc ] )

                        prev :: _ ->
                            let
                                valOK =
                                    cardValueToInt hc.card.value
                                        == cardValueToInt prev.card.value
                                        + 1

                                colorOK =
                                    LynRummy.Card.suitColor hc.card.suit
                                        /= LynRummy.Card.suitColor prev.card.suit
                            in
                            if valOK && colorOK then
                                ( acc, hc :: current )

                            else if List.length current >= 3 && isValidGroup (List.reverse current) then
                                ( List.reverse current :: acc, [ hc ] )

                            else
                                ( acc, [ hc ] )
                )
                ( [], [] )
                sorted
    in
    List.reverse
        (if List.length final >= 3 && isValidGroup (List.reverse final) then
            List.reverse final :: runs

         else
            runs
        )


isValidGroup : List HandCard -> Bool
isValidGroup cards =
    case getStackType (List.map .card cards) of
        Set ->
            True

        PureRun ->
            True

        RedBlackRun ->
            True

        _ ->
            False


makePlay : List HandCard -> Play
makePlay group =
    { trickId = "hand_stacks"
    , handCards = group
    , apply = applyHandStacks group
    }


applyHandStacks : List HandCard -> List CardStack -> ( List CardStack, List HandCard )
applyHandStacks group board =
    if isValidGroup group then
        ( pushNewStack board (List.map freshlyPlayed group)
        , group
        )

    else
        ( board, [] )
