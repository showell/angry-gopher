module Game.Strategy.SplitForSet exposing (trick)

{-| SPLIT_FOR_SET: a hand card of value V finds two same-value,
different-suit board cards that can be extracted, and the three
together form a new 3-set.

Mirrors `angry-gopher/lynrummy/tricks/split_for_set.go`.

-}

import Game.Card exposing (Card, Suit, suitToInt)
import Game.CardStack exposing (CardStack, HandCard, canExtract)
import Game.StackType exposing (CardStackType(..), getStackType)
import Game.Strategy.Helpers exposing (extractCard, freshlyPlayed, pushNewStack)
import Game.Strategy.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "split_for_set"
    , description = "Take two same-value cards out of the board and form a new set with your hand card."
    , findPlays = findPlays
    }


type alias Candidate =
    { stackIdx : Int
    , cardIdx : Int
    , card : Card
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand board =
    List.concatMap (\hc -> findPlaysForHandCard hc board) hand


findPlaysForHandCard : HandCard -> List CardStack -> List Play
findPlaysForHandCard hc board =
    let
        cands =
            findExtractableSameValue hc.card board
    in
    if List.length cands < 2 then
        []

    else
        case pickTwoDistinctSuits cands hc.card.suit of
            Nothing ->
                []

            Just ( a, b ) ->
                let
                    trio =
                        [ hc.card, a.card, b.card ]
                in
                if getStackType trio == Set then
                    [ makePlay hc a.card b.card ]

                else
                    []


findExtractableSameValue : Card -> List CardStack -> List Candidate
findExtractableSameValue target board =
    List.indexedMap Tuple.pair board
        |> List.concatMap
            (\( si, stack ) ->
                List.indexedMap Tuple.pair stack.boardCards
                    |> List.filterMap
                        (\( ci, bc ) ->
                            if
                                bc.card.value
                                    == target.value
                                    && bc.card.suit
                                    /= target.suit
                                    && canExtract stack ci
                            then
                                Just { stackIdx = si, cardIdx = ci, card = bc.card }

                            else
                                Nothing
                        )
            )


{-| Pick the first two candidates with distinct suits that
aren't the hand-card's suit.
-}
pickTwoDistinctSuits : List Candidate -> Suit -> Maybe ( Candidate, Candidate )
pickTwoDistinctSuits cands handSuit =
    case cands of
        [] ->
            Nothing

        first :: rest ->
            if first.card.suit == handSuit then
                pickTwoDistinctSuits rest handSuit

            else
                case findPartner first rest handSuit of
                    Just partner ->
                        Just ( first, partner )

                    Nothing ->
                        pickTwoDistinctSuits rest handSuit


findPartner : Candidate -> List Candidate -> Suit -> Maybe Candidate
findPartner first candidates handSuit =
    case candidates of
        [] ->
            Nothing

        c :: rest ->
            if c.card.suit == first.card.suit then
                findPartner first rest handSuit

            else if c.card.suit == handSuit then
                findPartner first rest handSuit

            else
                Just c


makePlay : HandCard -> Card -> Card -> Play
makePlay hc targetA targetB =
    { trickId = "split_for_set"
    , handCards = [ hc ]
    , apply = applySplitForSet hc targetA targetB
    }


applySplitForSet : HandCard -> Card -> Card -> List CardStack -> ( List CardStack, List HandCard )
applySplitForSet hc targetA targetB board =
    case relocate board targetA of
        Nothing ->
            ( board, [] )

        Just ( siA, ciA ) ->
            let
                ( board2, maybeExtA ) =
                    extractCard board siA ciA
            in
            case maybeExtA of
                Nothing ->
                    ( board, [] )

                Just extA ->
                    case relocate board2 targetB of
                        Nothing ->
                            ( board, [] )

                        Just ( siB, ciB ) ->
                            let
                                ( board3, maybeExtB ) =
                                    extractCard board2 siB ciB
                            in
                            case maybeExtB of
                                Nothing ->
                                    ( board, [] )

                                Just extB ->
                                    ( pushNewStack board3
                                        [ freshlyPlayed hc, extA, extB ]
                                    , [ hc ]
                                    )


{-| relocate finds (stackIdx, cardIdx) of `target` in the board
by value+suit+deck identity, with extractable position.
-}
relocate : List CardStack -> Card -> Maybe ( Int, Int )
relocate board target =
    let
        go si stacks =
            case stacks of
                [] ->
                    Nothing

                stack :: rest ->
                    case findInStack stack target of
                        Just ci ->
                            Just ( si, ci )

                        Nothing ->
                            go (si + 1) rest
    in
    go 0 board


findInStack : CardStack -> Card -> Maybe Int
findInStack stack target =
    let
        go ci cards =
            case cards of
                [] ->
                    Nothing

                bc :: rest ->
                    if
                        bc.card.value
                            == target.value
                            && bc.card.suit
                            == target.suit
                            && bc.card.originDeck
                            == target.originDeck
                            && canExtract stack ci
                    then
                        Just ci

                    else
                        go (ci + 1) rest
    in
    go 0 stack.boardCards

